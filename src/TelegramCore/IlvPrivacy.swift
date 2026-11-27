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
    /// Phone numbers, usernames and ids are hidden until tapped.
    case streamerMode
    /// An "ID" row in every profile.
    case showPeerId
    /// Cherry instead of blue as the default accent color of the built-in themes.
    case cherryAccent
    /// While "hide online" is on, messages are sent as scheduled a few seconds ahead.
    case ghostSending
    /// "Restrict saving content" is ignored on this device: copy, save, screenshots.
    case ignoreCopyProtection
    /// Screenshots of secret chats and view-once media are not reported to the sender.
    case hideScreenshots
    /// Earlier versions of edited messages are kept.
    case keepEditHistory
    /// A confirmation before every outgoing call.
    case confirmCalls
    /// Premium, Stars and gift rows are hidden in Settings.
    case hidePremiumPromos
    /// The stories bar is hidden and stories are not preloaded.
    case hideStories
    /// "Save to Gallery" for anyone's stories, without Premium.
    case downloadStories

    public var defaultValue: Bool {
        switch self {
        case .blockSponsored, .showChatGhostButton, .keepDeletedMessages, .keepSelfDestructing, .replayViewOnce, .showPeerId, .cherryAccent, .ghostSending, .ignoreCopyProtection, .hideScreenshots, .keepEditHistory, .confirmCalls, .downloadStories:
            return true
        case .hideReadReceipts, .hideStoryViews, .hideOnlineStatus, .hideTyping, .blurFacesInVideoMessages, .streamerMode, .hidePremiumPromos, .hideStories:
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
        if let value = IlvStore.shared.object(forKey: option.defaultsKey) as? Bool {
            return value
        }
        return option.defaultValue
    }

    public static func setEnabled(_ option: IlvPrivacyOption, _ value: Bool) {
        IlvStore.shared.set(value, forKey: option.defaultsKey)
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
        return (IlvStore.shared.dictionary(forKey: overridesKey) as? [String: Bool]) ?? [:]
    }

    /// true: ghost forced on for this chat, false: forced off, nil: global settings apply.
    public static func peerOverride(_ peerId: PeerId) -> Bool? {
        return overrides()[key(peerId)]
    }

    public static func setPeerOverride(_ peerId: PeerId, _ value: Bool?) {
        var current = overrides()
        current[key(peerId)] = value
        IlvStore.shared.set(current, forKey: overridesKey)
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
        IlvStore.shared.removeObject(forKey: overridesKey)
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

/// Methods after which the server marks the account online by itself.
private let ilvOnlineMarkingMethods: Set<String> = [
    "messagessendmessage",
    "messagessendmedia",
    "messagessendmultimedia",
    "messagesforwardmessages",
    "messagessendinlinebotresult",
    "messagessendreaction",
    "messagessendvote",
    "messageseditmessage",
    "messagessendscreenshotnotification",
    "storiessendstory"
]

/// Called for every outgoing request (edit "network-guard"). After sending a message the server
/// shows the account as online; while "hide online" is on, an offline status follows right after
/// the message so the online mark lasts a moment instead of minutes.
func ilvNoteRequest(_ name: String, network: Network) {
    if !IlvGhost.reportsOffline || !ilvOnlineMarkingMethods.contains(ilvNormalizeMethodName(name)) {
        return
    }
    for delay in [0.4, 1.5, 4.0] {
        Queue.concurrentDefaultQueue().after(delay, { [weak network] in
            guard let network = network else {
                return
            }
            let _ = network.request(Api.functions.account.updateStatus(offline: .boolTrue)).start()
        })
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
            store.ids = IlvStore.shared.stringArray(forKey: defaultsKey) ?? []
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
        IlvStore.shared.set(store.ids, forKey: defaultsKey)
    }

    /// Forgets the "deleted" marks. The messages themselves stay until the chat is cleared.
    public static func clearMarks() {
        store.lock.lock()
        defer { store.lock.unlock() }
        store.loaded = true
        store.ids = []
        store.set = []
        IlvStore.shared.removeObject(forKey: defaultsKey)
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

// MARK: - Location emulation

/// A fixed location reported instead of the device's GPS: in the location picker ("send my current
/// location"), for live locations and everywhere else the app asks DeviceLocationManager.
/// DeviceLocationManager reads the same UserDefaults keys directly (it does not link TelegramCore).
public enum IlvLocationEmulation {
    private static let enabledKey = "ilvtg.location.enabled"
    private static let latitudeKey = "ilvtg.location.lat"
    private static let longitudeKey = "ilvtg.location.lon"
    private static let versionPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    private static let versionCounter = Atomic<Int>(value: 0)

    public static var isEnabled: Bool {
        return IlvStore.shared.bool(forKey: enabledKey)
    }

    /// (latitude, longitude) while emulation is on.
    public static var coordinate: (Double, Double)? {
        if !isEnabled {
            return nil
        }
        return (IlvStore.shared.double(forKey: latitudeKey), IlvStore.shared.double(forKey: longitudeKey))
    }

    public static func enable(latitude: Double, longitude: Double) {
        IlvStore.shared.set(latitude, forKey: latitudeKey)
        IlvStore.shared.set(longitude, forKey: longitudeKey)
        IlvStore.shared.set(true, forKey: enabledKey)
        notify()
    }

    public static func disable() {
        IlvStore.shared.set(false, forKey: enabledKey)
        notify()
    }

    private static func notify() {
        versionPromise.set(versionCounter.modify { $0 + 1 })
    }

    /// Fires on subscription and on every change.
    public static var updates: Signal<Void, NoError> {
        return versionPromise.get() |> map { _ in Void() }
    }
}

// MARK: - Fake passcode

/// A second app passcode. Entering it on the lock screen logs every account out on the server,
/// wipes all local data and, if chosen, deletes the Telegram accounts for good.
public enum IlvDuress {
    public enum Action: Int {
        case logout = 0
        case deleteAccounts = 1
    }

    private static let keychainAccount = "duress"
    private static let actionKey = "ilvtg.duress.action"
    private static let pendingDeletionKey = "ilvtg.duress.pendingDeletion"

    /// salt (16 bytes) + PBKDF2 hash (32 bytes), in the Keychain of this device only.
    public static var isSet: Bool {
        return IlvKeychain.data(keychainAccount) != nil
    }

    public static func set(code: String) {
        let salt = IlvKeychain.randomSalt()
        let derived = IlvKeychain.derive(code, salt: salt)
        if derived.isEmpty {
            return
        }
        IlvKeychain.set(salt + derived, keychainAccount)
    }

    public static func clear() {
        IlvKeychain.set(nil, keychainAccount)
    }

    public static var action: Action {
        get {
            return Action(rawValue: IlvStore.shared.integer(forKey: actionKey)) ?? .logout
        }
        set {
            IlvStore.shared.set(newValue.rawValue, forKey: actionKey)
        }
    }

    public static func matches(_ code: String) -> Bool {
        guard !code.isEmpty, let stored = IlvKeychain.data(keychainAccount), stored.count == 48 else {
            return false
        }
        let salt = stored.prefix(16)
        let expected = stored.suffix(32)
        let derived = IlvKeychain.derive(code, salt: Data(salt))
        return !derived.isEmpty && derived == Data(expected)
    }

    /// Marks every account as logged out. managedCleanupAccounts then logs each one out on the
    /// server and deletes its data; with .deleteAccounts it deletes the account first
    /// (edit "duress-delete").
    public static func trigger(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        let deleteAccounts = action == .deleteAccounts
        IlvDeletedMessages.clearMarks()
        IlvEditHistory.clear()
        IlvGhost.resetPeerOverrides()
        let _ = (accountManager.transaction { transaction -> [AccountRecordId] in
            return transaction.getRecords().map { $0.id }
        }
        |> mapToSignal { ids -> Signal<Void, NoError> in
            if deleteAccounts {
                IlvStore.shared.set(ids.map { NSNumber(value: $0.int64) }, forKey: pendingDeletionKey)
            }
            return combineLatest(ids.map { logoutFromAccount(id: $0, accountManager: accountManager, alreadyLoggedOutRemotely: false) })
            |> map { _ in Void() }
        }).start()
    }

    /// Whether this account must be deleted (not only logged out); forgets the mark.
    static func takePendingDeletion(_ id: AccountRecordId) -> Bool {
        var pending = (IlvStore.shared.array(forKey: pendingDeletionKey) as? [NSNumber]) ?? []
        guard let index = pending.firstIndex(where: { $0.int64Value == id.int64 }) else {
            return false
        }
        pending.remove(at: index)
        IlvStore.shared.set(pending, forKey: pendingDeletionKey)
        return true
    }
}

/// Runs before auth.logOut while an account is being cleaned up.
func ilvDuressBeforeLogout(id: AccountRecordId, network: Network) -> Signal<Void, NoError> {
    if !IlvDuress.takePendingDeletion(id) {
        return .single(Void())
    }
    return network.request(Api.functions.account.deleteAccount(flags: 0, reason: "", password: nil))
    |> map { _ in Void() }
    |> `catch` { _ -> Signal<Void, NoError> in
        return .single(Void())
    }
    |> take(1)
}

// MARK: - Appearance and tab bar

public enum IlvAppearance {
    /// Read directly (same key) by ChatMessageBackground, which does not link TelegramCore.
    private static let bubbleAlphaKey = "ilvtg.bubbleAlpha"

    public static let bubbleAlphaPresets: [Double] = [1.0, 0.85, 0.7, 0.5, 0.3]

    /// Opacity of message bubbles, 1.0 = opaque.
    public static var bubbleAlpha: Double {
        get {
            let value = IlvStore.shared.double(forKey: bubbleAlphaKey)
            return value > 0.0 ? min(1.0, value) : 1.0
        }
        set {
            IlvStore.shared.set(newValue, forKey: bubbleAlphaKey)
        }
    }
}

public enum IlvTabs {
    /// Same keys are read directly by TabBarComponent, which does not link TelegramCore.
    private static let hideContactsKey = "ilvtg.tabs.hideContacts"
    private static let hideTitlesKey = "ilvtg.tabs.hideTitles"
    private static let versionPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    private static let versionCounter = Atomic<Int>(value: 0)

    public static var hideContacts: Bool {
        get {
            return IlvStore.shared.bool(forKey: hideContactsKey)
        }
        set {
            IlvStore.shared.set(newValue, forKey: hideContactsKey)
            notify()
        }
    }

    public static var hideTitles: Bool {
        get {
            return IlvStore.shared.bool(forKey: hideTitlesKey)
        }
        set {
            IlvStore.shared.set(newValue, forKey: hideTitlesKey)
            notify()
        }
    }

    private static func notify() {
        versionPromise.set(versionCounter.modify { $0 + 1 })
    }

    /// Fires after the first change, then on every change.
    public static var changed: Signal<Void, NoError> {
        return versionPromise.get() |> filter { $0 > 0 } |> map { _ in Void() }
    }
}

// MARK: - Locked chats

/// Chats that open only after Face ID / Touch ID / the device passcode. The check itself is in
/// TelegramUI (IlvChatLockGate).
public enum IlvChatLock {
    private static let key = "ilvtg.lockedChats"

    public static var lockedPeerIds: [Int64] {
        return (IlvStore.shared.array(forKey: key) as? [NSNumber])?.map { $0.int64Value } ?? []
    }

    public static func isLocked(_ peerId: PeerId) -> Bool {
        return lockedPeerIds.contains(peerId.toInt64())
    }

    public static func setLocked(_ peerId: PeerId, _ value: Bool) {
        var ids = lockedPeerIds.filter { $0 != peerId.toInt64() }
        if value {
            ids.append(peerId.toInt64())
        }
        IlvStore.shared.set(ids.map { NSNumber(value: $0) }, forKey: key)
    }
}
