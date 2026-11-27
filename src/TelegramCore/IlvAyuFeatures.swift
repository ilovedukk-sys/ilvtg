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

/// The server refuses to forward messages from protected chats. Text messages are sent as new
/// messages with the same text and formatting instead. Edit "protected-forwards".
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
    return account.postbox.transaction { transaction -> [(Bool, EnqueueMessage)] in
        return messages.map { transformed, message -> (Bool, EnqueueMessage) in
            guard case let .forward(source, threadId, _, attributes, correlationId) = message, let sourceMessage = transaction.getMessage(source), ilvIsServerCopyProtected(transaction: transaction, message: sourceMessage) else {
                return (transformed, message)
            }
            if sourceMessage.text.isEmpty || sourceMessage.media.contains(where: { !($0 is TelegramMediaWebpage) }) {
                return (transformed, message)
            }
            var updatedAttributes = attributes.filter { !($0 is ForwardOptionsMessageAttribute) }
            for attribute in sourceMessage.attributes {
                if let entities = attribute as? TextEntitiesMessageAttribute {
                    updatedAttributes.append(TextEntitiesMessageAttribute(entities: entities.entities))
                }
            }
            return (transformed, .message(text: sourceMessage.text, attributes: updatedAttributes, inlineStickers: [:], mediaReference: nil, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: correlationId, bubbleUpEmojiOrStickersets: []))
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
