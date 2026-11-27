// ilvtg — voice changer for voice and video messages.
// Copied into submodules/TelegramCore/Sources/Ilv/ by ci/prepare.py.
//
// A real-time pitch shifter: two read taps sweep through a short delay line at a rate set by
// the pitch ratio, crossfaded with complementary sin² windows. Tempo and duration stay the
// same, only the pitch moves. Cheap enough to run on every 20 ms recorder packet.

import Foundation

public enum IlvVoicePreset: Int, CaseIterable {
    case off = 0
    case lower = 1
    case muchLower = 2
    case higher = 3
    case muchHigher = 4

    public var pitchRatio: Float? {
        switch self {
        case .off:
            return nil
        case .lower:
            return 0.8
        case .muchLower:
            return 0.65
        case .higher:
            return 1.25
        case .muchHigher:
            return 1.5
        }
    }

    private static let defaultsKey = "ilvtg.voice.preset"

    public static var current: IlvVoicePreset {
        get {
            return IlvVoicePreset(rawValue: IlvStore.shared.integer(forKey: defaultsKey)) ?? .off
        }
        set {
            IlvStore.shared.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

public final class IlvVoiceChanger {
    private let ratio: Float
    private let window: Int
    private let capacity: Int
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var phase: Float = 0.0

    /// nil when the voice changer is off.
    public static func makeIfEnabled(sampleRate: Double) -> IlvVoiceChanger? {
        guard let ratio = IlvVoicePreset.current.pitchRatio else {
            return nil
        }
        return IlvVoiceChanger(ratio: ratio, sampleRate: sampleRate)
    }

    public init(ratio: Float, sampleRate: Double) {
        self.ratio = ratio
        // ~40 ms grains: long enough for low voices, short enough to avoid audible echo.
        self.window = max(256, Int(sampleRate * 0.04))
        self.capacity = self.window + 4
        self.buffer = Array(repeating: 0.0, count: self.capacity)
    }

    private func read(delay: Float) -> Float {
        var position = Float(self.writeIndex) - delay
        while position < 0.0 {
            position += Float(self.capacity)
        }
        let index0 = Int(position) % self.capacity
        let index1 = (index0 + 1) % self.capacity
        let fraction = position - Float(Int(position))
        return self.buffer[index0] * (1.0 - fraction) + self.buffer[index1] * fraction
    }

    private func processSample(_ input: Float) -> Float {
        self.buffer[self.writeIndex] = input

        let window = Float(self.window)
        self.phase += (1.0 - self.ratio) / window
        if self.phase >= 1.0 {
            self.phase -= 1.0
        } else if self.phase < 0.0 {
            self.phase += 1.0
        }
        var phase2 = self.phase + 0.5
        if phase2 >= 1.0 {
            phase2 -= 1.0
        }

        let gain1 = sinf(Float.pi * self.phase)
        let gain2 = sinf(Float.pi * phase2)
        let output = self.read(delay: self.phase * window) * gain1 * gain1 + self.read(delay: phase2 * window) * gain2 * gain2

        self.writeIndex += 1
        if self.writeIndex >= self.capacity {
            self.writeIndex = 0
        }
        return output
    }

    /// Processes mono or interleaved 16-bit PCM in place. `stride` is the channel count; each
    /// channel needs its own instance, so pass channel 0 here and duplicate it afterwards.
    public func process(_ samples: UnsafeMutablePointer<Int16>, count: Int, stride: Int = 1) {
        var index = 0
        while index < count {
            let output = self.processSample(Float(samples[index]))
            samples[index] = Int16(clamping: Int(output.rounded()))
            index += stride
        }
    }

    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int, stride: Int = 1) {
        var index = 0
        while index < count {
            samples[index] = self.processSample(samples[index] * 32768.0) / 32768.0
            index += stride
        }
    }
}
