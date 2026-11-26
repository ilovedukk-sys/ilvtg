// ilvtg — privacy layer for TelegramCore.
// Copied into submodules/TelegramCore/Sources/Ilv/ by ci/prepare.py.
//
// Two mechanisms:
// 1. Network.request / requestWithAdditionalInfo call ilvShouldBlockRequest() first (edit
//    "network-guard"): telemetry and sponsored content never leave the device.
// 2. Ghost mode works per chat, so it cannot be decided from the method name alone. Every call
//    site that sends a read receipt, a typing indicator or a story view goes through
//    Network.ilvGhostRequest(_:_:_:) instead (edits "ghost-*"). A blocked request fails with an
//    RPC error, which all of those call sites already swallow without retrying.

import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

public enum IlvPrivacyOption: String, CaseIterable {
    /// messages.readHistory and friends: the sender never sees the double check.
    case hideReadReceipts
    /// stories.readStories / incrementStoryViews: you are not listed among story viewers.
    case hideStoryViews
    /// account.updateStatus: the app reports "offline" instead of "online".
    case hideOnlineStatus
    /// messages.setTyping: no "typing…", "recording…", "uploading…" indicators.
    case hideTyping
    /// Ghost button next to the avatar in the chat header.
    case showChatGhostButton
    /// Sponsored messages in channels and the proxy promo channel are never requested.
    case blockSponsored
    /// Messages deleted by the other side stay in the chat, marked as deleted.
    case keepDeletedMessages
    /// Self-destruct timers do not delete messages or expire media on this device.
    case keepSelfDestructing
    /// View-once media is not marked as viewed, so it can be opened again.
    case replayViewOnce
    /// Faces in recorded video messages are pixelated before sending.
    case blurFacesInVideoMessages

    public var defaultValue: Bool {
        switch self {
        case .blockSponsored, .showChatGhostButton, .keepDeletedMessages, .keepSelfDestructing, .replayViewOnce:
            return true
        case .hideReadReceipts, .hideStoryViews, .hideOnlineStatus, .hideTyping, .blurFacesInVideoMessages:
            return false
        }
    }

    var defaultsKey: String {
        return "ilvtg.privacy." + self.rawValue
    }

    public static let ghostOptions: [IlvPrivacyOption] = [.hideReadReceipts, .hideStoryViews, .hideOnlineStatus, .hideTyping]
}

public enum IlvPrivacy {
    public static func isEnabled(_ option: IlvPrivacyOption) -> Bool {
        if let value = UserDefaults.standard.object(forKey: option.defaultsKey) as? Bool {
            return value
        }
        return option.defaultValue
    }

    public static func setEnabled(_ option: IlvPrivacyOption, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: option.defaultsKey)
    }

    /// Master switch on the settings tab: on when every ghost option is on.
    public static var isGhostModeEnabled: Bool {
        return IlvPrivacyOption.ghostOptions.allSatisfy { IlvPrivacy.isEnabled($0) }
    }

    public static func setGhostModeEnabled(_ value: Bool) {
        for option in IlvPrivacyOption.ghostOptions {
            IlvPrivacy.setEnabled(option, value)
        }
    }
}

// MARK: - Per-chat ghost mode

public enum IlvGhostFeature {
    case readReceipts
    case storyViews
    case typing

    var option: IlvPrivacyOption {
        switch self {
        case .readReceipts:
            return .hideReadReceipts
        case .storyViews:
            return .hideStoryViews
        case .typing:
            return .hideTyping
        }
    }
}

public enum IlvGhost {
    private static let overridesKey = "ilvtg.ghost.peers"

    private static func key(_ peerId: PeerId) -> String {
        return String(peerId.toInt64())
    }

    private static func overrides() -> [String: Bool] {
        return (UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Bool]) ?? [:]
    }

    /// true: ghost forced on for this chat, false: forced off, nil: global settings apply.
    public static func peerOverride(_ peerId: PeerId) -> Bool? {
        return overrides()[key(peerId)]
    }

    public static func setPeerOverride(_ peerId: PeerId, _ value: Bool?) {
        var current = overrides()
        current[key(peerId)] = value
        UserDefaults.standard.set(current, forKey: overridesKey)
    }

    /// What the ghost button in the chat header shows.
    public static func isEnabled(for peerId: PeerId) -> Bool {
        if let value = peerOverride(peerId) {
            return value
        }
        return IlvPrivacy.isEnabled(.hideReadReceipts)
    }

    /// Flips ghost mode for one chat and returns the new state.
    @discardableResult
    public static func toggle(_ peerId: PeerId) -> Bool {
        let updated = !isEnabled(for: peerId)
        setPeerOverride(peerId, updated)
        return updated
    }

    public static var overriddenChatCount: Int {
        return overrides().count
    }

    public static func resetPeerOverrides() {
        UserDefaults.standard.removeObject(forKey: overridesKey)
    }

    static func isActive(_ feature: IlvGhostFeature, peerId: PeerId?) -> Bool {
        if let peerId = peerId, let value = peerOverride(peerId) {
            return value
        }
        return IlvPrivacy.isEnabled(feature.option)
    }

    /// Presence ping: "offline" instead of "online" while ghost mode hides the online status.
    static var reportsOffline: Bool {
        return IlvPrivacy.isEnabled(.hideOnlineStatus)
    }
}

extension Network {
    func ilvGhostRequest<T>(_ feature: IlvGhostFeature, _ peerId: PeerId?, _ data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>)) -> Signal<T, MTRpcError> {
        if IlvGhost.isActive(feature, peerId: peerId) {
            return .fail(MTRpcError(errorCode: 400, errorDescription: "ILVTG_PRIVACY_BLOCKED"))
        }
        return self.request(data)
    }
}

// MARK: - Method-name guard (telemetry, sponsored content)

/// Telemetry that is never sent, regardless of settings: app event logs and call debug logs.
private let ilvAlwaysBlockedMethods: Set<String> = [
    "helpsaveapplog",
    "phonesavecalldebug",
    "phonesavecalllog"
]

private let ilvSponsoredMethods: Set<String> = [
    "messagesgetsponsoredmessages",
    "messagesviewsponsoredmessage",
    "messagesclicksponsoredmessage",
    "helpgetpromodata"
]

/// "messages.readHistory" -> "messagesreadhistory". Robust against however the generated API
/// spells the qualified name (dot, underscore, case).
func ilvNormalizeMethodName(_ name: String) -> String {
    var result = ""
    result.reserveCapacity(name.count)
    for scalar in name.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
    }
    return result.lowercased()
}

func ilvShouldBlockRequest(_ name: String) -> Bool {
    let method = ilvNormalizeMethodName(name)
    if ilvAlwaysBlockedMethods.contains(method) {
        return true
    }
    if ilvSponsoredMethods.contains(method) && IlvPrivacy.isEnabled(.blockSponsored) {
        return true
    }
    return false
}

// MARK: - Deleted messages

/// Ids of messages the server deleted while "keep deleted messages" was on. They stay in the
/// local database; the chat shows "deleted" next to their time.
public enum IlvDeletedMessages {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var loaded = false
        var ids: [String] = []
        var set = Set<String>()
    }

    private static let store = Store()
    private static let defaultsKey = "ilvtg.deleted.v1"
    private static let limit = 20000

    private static func key(_ id: MessageId) -> String {
        return "\(id.peerId.toInt64()):\(id.namespace):\(id.id)"
    }

    private static func loadIfNeeded() {
        if !store.loaded {
            store.loaded = true
            store.ids = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
            store.set = Set(store.ids)
        }
    }

    public static func contains(_ id: MessageId) -> Bool {
        store.lock.lock()
        defer { store.lock.unlock() }
        loadIfNeeded()
        return store.set.contains(key(id))
    }

    public static var count: Int {
        store.lock.lock()
        defer { store.lock.unlock() }
        loadIfNeeded()
        return store.ids.count
    }

    static func add(_ ids: [MessageId]) {
        if ids.isEmpty {
            return
        }
        store.lock.lock()
        defer { store.lock.unlock() }
        loadIfNeeded()
        for id in ids {
            let value = key(id)
            if !store.set.contains(value) {
                store.set.insert(value)
                store.ids.append(value)
            }
        }
        if store.ids.count > limit {
            let removed = store.ids.prefix(store.ids.count - limit)
            for value in removed {
                store.set.remove(value)
            }
            store.ids.removeFirst(removed.count)
        }
        UserDefaults.standard.set(store.ids, forKey: defaultsKey)
    }

    /// Forgets the "deleted" marks. The messages themselves stay until the chat is cleared.
    public static func clearMarks() {
        store.lock.lock()
        defer { store.lock.unlock() }
        store.loaded = true
        store.ids = []
        store.set = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// Called instead of deleting messages when the server reports them deleted.
func ilvKeepDeletedMessages(transaction: Transaction, ids: [MessageId]) {
    let existing = ids.filter { transaction.getMessage($0) != nil }
    IlvDeletedMessages.add(existing)
    for id in existing {
        // Rewrite the message unchanged so open chats re-render it with the "deleted" mark.
        transaction.updateMessage(id, update: { currentMessage in
            var storeForwardInfo: StoreMessageForwardInfo?
            if let forwardInfo = currentMessage.forwardInfo {
                storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
            }
            return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: currentMessage.attributes, media: currentMessage.media))
        })
    }
}

func ilvKeepDeletedMessages(transaction: Transaction, globalIds: [Int32]) {
    ilvKeepDeletedMessages(transaction: transaction, ids: transaction.messageIdsForGlobalIds(globalIds))
}

// MARK: - Self-destructing and view-once messages

/// Whether opening this message must not mark it as viewed (view-once replay).
func ilvSkipsConsumption(_ message: Message) -> Bool {
    if !IlvPrivacy.isEnabled(.replayViewOnce) {
        return false
    }
    for attribute in message.attributes {
        if attribute is AutoclearTimeoutMessageAttribute {
            return true
        }
        if attribute is AutoremoveTimeoutMessageAttribute && message.id.peerId.namespace == Namespaces.Peer.SecretChat {
            return true
        }
    }
    return false
}
