// ilvtg — features inspired by AyuGram, written for ilvtg (no third-party servers involved):
// sending without going online, forwards from protected chats, reading a chat on demand while
// ghost mode is on, and the edit history of messages.
// Copied into submodules/TelegramCore/Sources/Ilv/ by ci/prepare.py.

import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

// MARK: - Sending without going online

private let ilvGhostSendDelay: Int32 = 12

private func ilvIsServiceMessage(_ message: EnqueueMessage) -> Bool {
    if case let .message(_, _, _, mediaReference, _, _, _, _, _, _) = message, mediaReference?.media is TelegramMediaAction {
        return true
    }
    return false
}

/// While "hide online" is on, sent messages are scheduled a few seconds ahead. The server
/// publishes scheduled messages by itself and does not mark the sender online for them.
/// Edit "ghost-sending" runs this in enqueueMessages.
func ilvPrepareGhostSending(account: Account, peerId: PeerId, messages: [(Bool, EnqueueMessage)]) -> Signal<[(Bool, EnqueueMessage)], NoError> {
    guard IlvPrivacy.isEnabled(.ghostSending), IlvGhost.reportsOffline, peerId != account.peerId, peerId.namespace != Namespaces.Peer.SecretChat else {
        return .single(messages)
    }
    return account.postbox.transaction { transaction -> Bool in
        if let user = transaction.getPeer(peerId) as? TelegramUser, user.botInfo != nil {
            return false
        }
        return true
    }
    |> map { canSchedule -> [(Bool, EnqueueMessage)] in
        if !canSchedule {
            return messages
        }
        let scheduleTime = Int32(Date().timeIntervalSince1970) + ilvGhostSendDelay
        return messages.map { transformed, message -> (Bool, EnqueueMessage) in
            if ilvIsServiceMessage(message) {
                return (transformed, message)
            }
            return (transformed, message.withUpdatedAttributes { attributes in
                if attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute || $0 is OutgoingQuickReplyMessageAttribute }) {
                    return attributes
                }
                return attributes + [OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: nil)]
            })
        }
    }
}

// MARK: - Protected content

/// The protection the server enforces, whatever the local bypass says.
private func ilvIsServerCopyProtected(transaction: Transaction, message: Message) -> Bool {
    if message.flags.contains(.CopyProtected) {
        return true
    }
    if let group = transaction.getPeer(message.id.peerId) as? TelegramGroup, group.flags.contains(.copyProtectionEnabled) {
        return true
    }
    if let channel = transaction.getPeer(message.id.peerId) as? TelegramChannel, channel.flags.contains(.copyProtectionEnabled) {
        return true
    }
    if let cachedUserData = transaction.getPeerCachedData(peerId: message.id.peerId) as? CachedUserData, cachedUserData.flags.contains(.copyProtectionEnabled) || cachedUserData.flags.contains(.myCopyProtectionEnabled) {
        return true
    }
    return false
}

/// The server refuses to forward messages from protected chats and to reuse their media. Such
/// forwards are sent as new messages instead: the text and formatting are copied, and photos,
/// videos, voice messages and files are downloaded and uploaded again as new files. Albums stay
/// grouped. A message that cannot be copied keeps its original forward request.
/// Edit "ghost-sending" runs this in enqueueMessages.
func ilvPrepareProtectedForwards(account: Account, messages: [(Bool, EnqueueMessage)]) -> Signal<[(Bool, EnqueueMessage)], NoError> {
    let hasForwards = messages.contains(where: { _, message in
        if case .forward = message {
            return true
        }
        return false
    })
    guard IlvPrivacy.isEnabled(.ignoreCopyProtection), hasForwards else {
        return .single(messages)
    }
    return account.postbox.transaction { transaction -> [Int: Message] in
        var sources: [Int: Message] = [:]
        for index in 0 ..< messages.count {
            if case let .forward(sourceId, _, _, _, _) = messages[index].1, let source = transaction.getMessage(sourceId), ilvIsServerCopyProtected(transaction: transaction, message: source) {
                sources[index] = source
            }
        }
        return sources
    }
    |> mapToSignal { sources -> Signal<[(Bool, EnqueueMessage)], NoError> in
        if sources.isEmpty {
            return .single(messages)
        }
        var groupingKeys: [Int64: Int64] = [:]
        var signals: [Signal<(Bool, EnqueueMessage), NoError>] = []
        for index in 0 ..< messages.count {
            let original = messages[index]
            guard let source = sources[index], case let .forward(_, threadId, grouping, attributes, correlationId) = original.1 else {
                signals.append(.single(original))
                continue
            }
            var localGroupingKey: Int64?
            if case .auto = grouping, let sourceKey = source.groupingKey {
                if let current = groupingKeys[sourceKey] {
                    localGroupingKey = current
                } else {
                    let value = Int64.random(in: 1 ... Int64.max)
                    groupingKeys[sourceKey] = value
                    localGroupingKey = value
                }
            }
            signals.append(ilvCopyProtectedMessage(account: account, source: source, threadId: threadId, attributes: attributes, correlationId: correlationId, localGroupingKey: localGroupingKey)
            |> map { copy -> (Bool, EnqueueMessage) in
                return copy ?? original
            })
        }
        return combineLatest(signals)
    }
}

private func ilvCopyProtectedMessage(account: Account, source: Message, threadId: Int64?, attributes: [MessageAttribute], correlationId: Int64?, localGroupingKey: Int64?) -> Signal<(Bool, EnqueueMessage)?, NoError> {
    var hideCaptions = false
    var outgoingAttributes: [MessageAttribute] = []
    for attribute in attributes {
        if let options = attribute as? ForwardOptionsMessageAttribute {
            hideCaptions = options.hideCaptions
        } else {
            outgoingAttributes.append(attribute)
        }
    }
    let media = source.media.first(where: { !($0 is TelegramMediaWebpage) })
    let text = hideCaptions && media != nil ? "" : source.text
    if !text.isEmpty, let entities = source.textEntitiesAttribute?.entities, !entities.isEmpty {
        outgoingAttributes.append(TextEntitiesMessageAttribute(entities: entities))
    }
    let messageAttributes = outgoingAttributes

    func makeMessage(_ mediaReference: AnyMediaReference?) -> (Bool, EnqueueMessage) {
        return (true, .message(text: text, attributes: messageAttributes, inlineStickers: [:], mediaReference: mediaReference, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: []))
    }

    guard let media = media else {
        return .single(text.isEmpty ? nil : makeMessage(nil))
    }
    if let image = media as? TelegramMediaImage, let largest = largestImageRepresentation(image.representations) {
        return ilvLocalCopy(account: account, source: source, media: image, resource: largest.resource, size: nil)
        |> map { resource -> (Bool, EnqueueMessage)? in
            guard let resource = resource else {
                return nil
            }
            let copy = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: Int64.random(in: Int64.min ... Int64.max)), representations: [TelegramMediaImageRepresentation(dimensions: largest.dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: image.immediateThumbnailData, reference: nil, partialReference: nil, flags: [])
            return makeMessage(.standalone(media: copy))
        }
    } else if let file = media as? TelegramMediaFile {
        if file.isSticker || file.isAnimatedSticker || file.isVideoSticker || file.isCustomEmoji {
            // Stickers from packs are public documents and can be reused as they are.
            return .single(makeMessage(.standalone(media: file)))
        }
        return ilvLocalCopy(account: account, source: source, media: file, resource: file.resource, size: file.size)
        |> map { resource -> (Bool, EnqueueMessage)? in
            guard let resource = resource else {
                return nil
            }
            let copy = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: file.attributes, alternativeRepresentations: [])
            return makeMessage(.standalone(media: copy))
        }
    } else if media is TelegramMediaContact {
        return .single(makeMessage(.standalone(media: media)))
    } else if let map = media as? TelegramMediaMap, map.liveBroadcastingTimeout == nil {
        return .single(makeMessage(.standalone(media: map)))
    } else {
        return .single(nil)
    }
}

/// Downloads the resource if needed and copies it into a new local resource, which the pending
/// message manager uploads as a new file. nil if the download fails.
private func ilvLocalCopy(account: Account, source: Message, media: Media, resource: MediaResource, size: Int64?) -> Signal<TelegramMediaResource?, NoError> {
    let mediaBox = account.postbox.mediaBox
    let fetch = fetchedMediaResource(mediaBox: mediaBox, userLocation: .peer(source.id.peerId), userContentType: .other, reference: .media(media: .message(message: MessageReference(source), media: media), resource: resource))
    let completeData = mediaBox.resourceData(resource)
    |> filter { $0.complete }
    |> take(1)
    return Signal { subscriber in
        let fetchDisposable = fetch.start(error: { _ in
            subscriber.putNext(nil)
            subscriber.putCompletion()
        })
        let dataDisposable = completeData.start(next: { _ in
            let localResource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max), size: size)
            mediaBox.copyResourceData(from: resource.id, to: localResource.id, synchronous: true)
            subscriber.putNext(localResource)
            subscriber.putCompletion()
        })
        return ActionDisposable {
            fetchDisposable.dispose()
            dataDisposable.dispose()
        }
    }
}

// MARK: - Reading a chat on demand

/// Sends the read receipt for the whole chat now, ghost mode or not. Returns whether the server
/// accepted it.
public func ilvMarkChatReadOnServer(account: Account, peerId: PeerId) -> Signal<Bool, NoError> {
    return account.postbox.transaction { transaction -> (Peer, Int32)? in
        guard let peer = transaction.getPeer(peerId), let topId = transaction.getTopPeerMessageId(peerId: peerId, namespace: Namespaces.Message.Cloud) else {
            return nil
        }
        return (peer, topId.id)
    }
    |> mapToSignal { value -> Signal<Bool, NoError> in
        guard let value = value else {
            return .single(false)
        }
        let (peer, maxId) = value
        if peerId.namespace == Namespaces.Peer.CloudChannel {
            guard let inputChannel = apiInputChannel(peer) else {
                return .single(false)
            }
            return account.network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: maxId))
            |> map { _ -> Bool in
                return true
            }
            |> `catch` { _ -> Signal<Bool, NoError> in
                return .single(false)
            }
        } else if peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.CloudGroup {
            guard let inputPeer = apiInputPeer(peer) else {
                return .single(false)
            }
            let stateManager = account.stateManager
            return account.network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: maxId))
            |> map { result -> Bool in
                switch result {
                case let .affectedMessages(affectedMessagesData):
                    stateManager?.addUpdateGroups([.updatePts(pts: affectedMessagesData.pts, ptsCount: affectedMessagesData.ptsCount)])
                }
                return true
            }
            |> `catch` { _ -> Signal<Bool, NoError> in
                return .single(false)
            }
        } else {
            return .single(false)
        }
    }
}

// MARK: - Edit history

public struct IlvEditVersion: Codable, Equatable {
    public let text: String
    /// When this version was posted or last edited.
    public let date: Int32
}

/// Earlier versions of messages edited by their authors, kept on this device in a file inside
/// the app's protected container. Edit "edit-history" records them.
public enum IlvEditHistory {
    private final class Store {
        let lock = NSLock()
        var loaded = false
        var versions: [String: [IlvEditVersion]] = [:]
        var order: [String] = []
    }

    private struct Snapshot: Codable {
        var versions: [String: [IlvEditVersion]]
        var order: [String]
    }

    private static let store = Store()
    private static let messageLimit = 5000
    private static let versionLimit = 20
    private static let saveQueue = Queue(name: "org.ilvtg.edit-history")

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("ilvtg", isDirectory: true).appendingPathComponent("edit-history.json")
    }

    private static func key(_ id: MessageId) -> String {
        return "\(id.peerId.toInt64()):\(id.namespace):\(id.id)"
    }

    private static func loadIfNeeded() {
        if store.loaded {
            return
        }
        store.loaded = true
        if let url = fileURL, let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            store.versions = snapshot.versions
            store.order = snapshot.order
        }
    }

    private static func save(_ snapshot: Snapshot) {
        saveQueue.async {
            guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else {
                return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func record(_ id: MessageId, previousText: String, date: Int32) {
        store.lock.lock()
        loadIfNeeded()
        let messageKey = key(id)
        var list = store.versions[messageKey] ?? []
        if list.last?.text == previousText {
            store.lock.unlock()
            return
        }
        if list.isEmpty {
            store.order.append(messageKey)
        }
        list.append(IlvEditVersion(text: previousText, date: date))
        if list.count > versionLimit {
            list.removeFirst(list.count - versionLimit)
        }
        store.versions[messageKey] = list
        if store.order.count > messageLimit {
            let removed = store.order.prefix(store.order.count - messageLimit)
            for value in removed {
                store.versions.removeValue(forKey: value)
            }
            store.order.removeFirst(removed.count)
        }
        let snapshot = Snapshot(versions: store.versions, order: store.order)
        store.lock.unlock()
        save(snapshot)
    }

    /// Earlier versions, oldest first. Empty if the message was never edited while recording.
    public static func versions(_ id: MessageId) -> [IlvEditVersion] {
        store.lock.lock()
        defer { store.lock.unlock() }
        loadIfNeeded()
        return store.versions[key(id)] ?? []
    }

    public static var count: Int {
        store.lock.lock()
        defer { store.lock.unlock() }
        loadIfNeeded()
        return store.order.count
    }

    public static func clear() {
        store.lock.lock()
        store.loaded = true
        store.versions = [:]
        store.order = []
        store.lock.unlock()
        saveQueue.async {
            if let url = fileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// Called with the stored message before an edit from the server replaces it.
func ilvRecordEdit(previous: Message, updatedText: String) {
    guard IlvPrivacy.isEnabled(.keepEditHistory), previous.flags.contains(.Incoming), !previous.text.isEmpty, previous.text != updatedText else {
        return
    }
    var date = previous.timestamp
    for attribute in previous.attributes {
        if let edited = attribute as? EditedMessageAttribute {
            date = edited.date
        }
    }
    IlvEditHistory.record(previous.id, previousText: previous.text, date: date)
}
