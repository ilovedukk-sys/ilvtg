// ilvtg — post-processing of recorded video messages: pixelates faces and changes the voice.
// Copied into submodules/TelegramUI/Components/VideoMessageCameraScreen/Sources/ by
// ci/prepare.py. Every finished recording segment passes through ilvProcessVideoMessageResult
// before the screen sees it (edit "video-message-process"); live upload of the unprocessed file
// is disabled while either feature is on (edit "video-message-no-live-upload").

import Foundation
import UIKit
import AVFoundation
import CoreImage
import Vision
import SwiftSignalKit
import TelegramCore

var ilvVideoMessageProcessingEnabled: Bool {
    return IlvPrivacy.isEnabled(.blurFacesInVideoMessages) || IlvVoicePreset.current.pitchRatio != nil
}

private final class IlvFaceTracker {
    private var lastFaces: [CGRect] = []
    private var framesSinceDetection = 0
    private var frameIndex = 0

    /// Normalized face rectangles (Vision coordinates, origin bottom-left). Detection runs on
    /// every second frame, and the last result is kept for a few frames so a single missed
    /// detection does not uncover a face.
    func faces(in image: CIImage) -> [CGRect] {
        self.frameIndex += 1
        if self.frameIndex % 2 == 0 && !self.lastFaces.isEmpty {
            return self.lastFaces
        }
        let extent = image.extent
        if extent.isInfinite || extent.isEmpty || extent.width < 16.0 || extent.height < 16.0 {
            return self.lastFaces
        }
        // A fresh request per frame: Vision requests are not meant to be reused across handlers.
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        var detected: [CGRect] = []
        do {
            try handler.perform([request])
            detected = (request.results ?? []).map { $0.boundingBox }.filter { rect in
                return rect.width.isFinite && rect.height.isFinite && rect.width > 0.0 && rect.height > 0.0
            }
        } catch {
            detected = []
        }
        if detected.isEmpty {
            self.framesSinceDetection += 1
            if self.framesSinceDetection > 12 {
                self.lastFaces = []
            }
        } else {
            self.framesSinceDetection = 0
            self.lastFaces = detected
        }
        return self.lastFaces
    }
}

private func ilvOrientation(for transform: CGAffineTransform) -> (CGImagePropertyOrientation, CGImagePropertyOrientation) {
    let angle = atan2(transform.b, transform.a)
    if abs(angle - .pi / 2.0) < 0.1 {
        return (.right, .left)
    } else if abs(angle + .pi / 2.0) < 0.1 {
        return (.left, .right)
    } else if abs(abs(angle) - .pi) < 0.1 {
        return (.down, .down)
    } else {
        return (.up, .up)
    }
}

private func ilvBlurFaces(_ image: CIImage, faces: [CGRect]) -> CIImage {
    if faces.isEmpty {
        return image
    }
    let extent = image.extent
    let scale = max(8.0, max(extent.width, extent.height) / 14.0)
    let pixelated = image.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale])
    var result = image
    for face in faces {
        var rect = CGRect(x: extent.minX + face.minX * extent.width, y: extent.minY + face.minY * extent.height, width: face.width * extent.width, height: face.height * extent.height)
        // Cover hair, ears and chin, not only the detected box.
        rect = rect.insetBy(dx: -rect.width * 0.35, dy: -rect.height * 0.45).intersection(extent)
        if rect.isNull || rect.isEmpty {
            continue
        }
        result = pixelated.cropped(to: rect).composited(over: result)
    }
    return result.cropped(to: extent)
}

private enum IlvVideoProcessingError: Error {
    case failed
}

/// Re-encodes `input` into `output`: H.264 video with faces pixelated (if enabled) and AAC audio
/// with the voice changed (if enabled). Synchronous; call it off the main thread.
private func ilvProcessVideoFile(input: URL, output: URL, blurFaces: Bool, pitchRatio: Float?) throws {
    let asset = AVURLAsset(url: input)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        throw IlvVideoProcessingError.failed
    }
    let audioTrack = asset.tracks(withMediaType: .audio).first

    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true

    let naturalSize = videoTrack.naturalSize
    let width = Int(naturalSize.width.rounded())
    let height = Int(naturalSize.height.rounded())

    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else {
        throw IlvVideoProcessingError.failed
    }
    reader.add(videoOutput)

    let estimatedBitrate = videoTrack.estimatedDataRate > 0.0 ? Int(videoTrack.estimatedDataRate) : 1_000_000
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: max(600_000, estimatedBitrate),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
    ])
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = videoTrack.preferredTransform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    guard writer.canAdd(videoInput) else {
        throw IlvVideoProcessingError.failed
    }
    writer.add(videoInput)

    // Video messages are mono speech: decode to 48 kHz mono 16-bit PCM (the reader resamples and
    // downmixes as needed) and encode back to AAC.
    let sampleRate: Double = 48000.0
    let channelCount = 1
    var audioOutput: AVAssetReaderTrackOutput?
    var audioInput: AVAssetWriterInput?
    if let audioTrack = audioTrack {
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount
        ])
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 64000
        ])
        input.expectsMediaDataInRealTime = false
        if reader.canAdd(output) && writer.canAdd(input) {
            reader.add(output)
            writer.add(input)
            audioOutput = output
            audioInput = input
        }
    }

    let ciContext = CIContext(options: [.cacheIntermediates: false])
    let faceTracker = IlvFaceTracker()
    let (orientation, inverseOrientation) = ilvOrientation(for: videoTrack.preferredTransform)
    var voiceChangers: [IlvVoiceChanger] = []
    if let pitchRatio = pitchRatio, audioInput != nil {
        for _ in 0 ..< channelCount {
            voiceChangers.append(IlvVoiceChanger(ratio: pitchRatio, sampleRate: sampleRate))
        }
    }

    guard reader.startReading(), writer.startWriting() else {
        throw IlvVideoProcessingError.failed
    }
    writer.startSession(atSourceTime: .zero)

    var videoDone = false
    var audioDone = audioInput == nil
    let deadline = Date().addingTimeInterval(180.0)

    while !videoDone || !audioDone {
        if Date() > deadline || reader.status == .failed || writer.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            throw IlvVideoProcessingError.failed
        }
        // Each frame allocates autoreleased Core Image and Vision objects; without a pool per
        // iteration a long recording runs the app out of memory.
        let progressed = autoreleasepool { () -> Bool in
        var didProgress = false

        if !videoDone && videoInput.isReadyForMoreMediaData {
            didProgress = true
            if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    if blurFaces, let pool = adaptor.pixelBufferPool {
                        var outputBuffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
                        if let outputBuffer = outputBuffer {
                            let source = CIImage(cvPixelBuffer: pixelBuffer)
                            let upright = source.oriented(orientation)
                            let faces = faceTracker.faces(in: upright)
                            let processed = ilvBlurFaces(upright, faces: faces).oriented(inverseOrientation)
                            ciContext.render(processed, to: outputBuffer, bounds: CGRect(x: 0.0, y: 0.0, width: CGFloat(CVPixelBufferGetWidth(outputBuffer)), height: CGFloat(CVPixelBufferGetHeight(outputBuffer))), colorSpace: CGColorSpaceCreateDeviceRGB())
                            if !adaptor.append(outputBuffer, withPresentationTime: time) {
                                videoDone = true
                                videoInput.markAsFinished()
                            }
                        }
                    } else if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                        videoDone = true
                        videoInput.markAsFinished()
                    }
                }
            } else {
                videoDone = true
                videoInput.markAsFinished()
            }
        }

        if !audioDone, let audioOutput = audioOutput, let audioInput = audioInput, audioInput.isReadyForMoreMediaData {
            didProgress = true
            if let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                if !voiceChangers.isEmpty, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    var length = 0
                    var dataPointer: UnsafeMutablePointer<Int8>?
                    if CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr, let dataPointer = dataPointer, CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: length) {
                        let sampleCount = length / 2
                        dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                            for channel in 0 ..< voiceChangers.count {
                                voiceChangers[channel].process(samples.advanced(by: channel), count: sampleCount - channel, stride: voiceChangers.count)
                            }
                        }
                    }
                }
                if !audioInput.append(sampleBuffer) {
                    audioDone = true
                    audioInput.markAsFinished()
                }
            } else {
                audioDone = true
                audioInput.markAsFinished()
            }
        }

        return didProgress
        }

        if !progressed {
            usleep(2000)
        }
    }

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    semaphore.wait()
    if writer.status != .completed {
        throw IlvVideoProcessingError.failed
    }
}

/// Runs the enabled processing on a finished recording segment and hands the result (or the
/// original, if processing is off or fails) to `completion` on the main queue.
func ilvProcessVideoMessageResult(_ result: VideoMessageCameraScreen.CaptureResult, completion: @escaping (VideoMessageCameraScreen.CaptureResult) -> Void) {
    guard ilvVideoMessageProcessingEnabled, case let .video(video) = result else {
        completion(result)
        return
    }
    let blurFaces = IlvPrivacy.isEnabled(.blurFacesInVideoMessages)
    let pitchRatio = IlvVoicePreset.current.pitchRatio

    Queue.concurrentDefaultQueue().async {
        let input = URL(fileURLWithPath: video.videoPath)
        let output = input.deletingLastPathComponent().appendingPathComponent("ilvtg-\(Int64.random(in: 1 ... Int64.max)).mp4")
        var processed = result
        do {
            try ilvProcessVideoFile(input: input, output: output, blurFaces: blurFaces, pitchRatio: pitchRatio)
            processed = .video(VideoMessageCameraScreen.CaptureResult.Video(videoPath: output.path, dimensions: video.dimensions, duration: video.duration, thumbnail: ilvProcessedThumbnail(video.thumbnail, blurFaces: blurFaces)))
            // The unprocessed recording must not end up anywhere else.
            let _ = try? FileManager.default.removeItem(at: input)
        } catch {
            let _ = try? FileManager.default.removeItem(at: output)
        }
        Queue.mainQueue().async {
            completion(processed)
        }
    }
}

private func ilvProcessedThumbnail(_ image: UIImage, blurFaces: Bool) -> UIImage {
    guard blurFaces, let cgImage = image.cgImage else {
        return image
    }
    let source = CIImage(cgImage: cgImage)
    let faces = IlvFaceTracker().faces(in: source)
    // Without a detected face, the thumbnail (also used as the preview) is pixelated as a whole.
    let processed = faces.isEmpty ? ilvBlurFaces(source, faces: [CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)]) : ilvBlurFaces(source, faces: faces)
    let context = CIContext(options: nil)
    guard let output = context.createCGImage(processed, from: source.extent) else {
        return image
    }
    return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
}
