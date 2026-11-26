#!/usr/bin/env python3
"""Turn a pristine Telegram-iOS checkout (pinned in upstream.json) into ilvtg.

Every change is an exact-text edit with an expected match count. If upstream code drifts and an
anchor no longer matches, the script stops with the file and the edit name instead of producing
a build that silently lacks a privacy change.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read_exact(path: Path) -> str:
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def write_exact(path: Path, text: str):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


class Tree:
    """Applies edits to the checkout. With dry_run, edits are kept in memory and nothing is
    written, so the whole patch set can be checked against an unpacked source archive."""

    def __init__(self, source: Path, dry_run: bool = False):
        self.source = source
        self.dry_run = dry_run
        self.pending = {}
        self.applied = []

    def _read(self, relpath: str) -> str:
        if relpath in self.pending:
            return self.pending[relpath]
        return read_exact(self.source / relpath)

    def _write(self, relpath: str, text: str):
        if self.dry_run:
            self.pending[relpath] = text
        else:
            write_exact(self.source / relpath, text)

    def edit(self, name: str, relpath: str, old: str, new: str, count: int = 1):
        text = self._read(relpath)
        found = text.count(old)
        if found != count:
            raise SystemExit(f"[ilvtg] edit '{name}': expected {count} match(es) in {relpath}, found {found}")
        self._write(relpath, text.replace(old, new))
        self.applied.append(name)

    def copy(self, name: str, src: Path, relpath: str):
        dst = self.source / relpath
        if dst.exists() or relpath in self.pending:
            raise SystemExit(f"[ilvtg] copy '{name}': {relpath} already exists")
        if not src.is_file():
            raise SystemExit(f"[ilvtg] copy '{name}': {src} is missing")
        if self.dry_run:
            self.pending[relpath] = read_exact(src)
        else:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        self.applied.append(name)

    def append(self, name: str, relpath: str, text: str):
        current = self._read(relpath)
        if not current.endswith("\n"):
            current += "\n"
        self._write(relpath, current + text)
        self.applied.append(name)


CORE = "submodules/TelegramCore/Sources/"


def ghost(t: Tree, name: str, relpath: str, method: str, feature: str, peer: str, count: int = 1):
    """Route one ghost-mode request through Network.ilvGhostRequest, which knows the chat."""
    t.edit(name, CORE + relpath,
           f"network.request(Api.functions.{method}(",
           f"network.ilvGhostRequest(.{feature}, {peer}, Api.functions.{method}(",
           count=count)


def privacy_layer(t: Tree):
    for name in ["IlvPrivacy", "IlvVoice", "IlvChatExport"]:
        t.copy("core-" + name, ROOT / f"src/TelegramCore/{name}.swift", CORE + f"Ilv/{name}.swift")

    # Single choke point for telemetry and sponsored content: both request entry points of
    # Network refuse those methods.
    t.edit("network-guard", CORE + "Network/Network.swift",
           "        return Signal { [requestService] subscriber in\n"
           "            let request = NetworkEngineRequest(\n",
           "        return Signal { [requestService] subscriber in\n"
           "            if ilvShouldBlockRequest(data.0.name) {\n"
           "                subscriber.putError(MTRpcError(errorCode: 400, errorDescription: \"ILVTG_PRIVACY_BLOCKED\"))\n"
           "                return EmptyDisposable\n"
           "            }\n"
           "            let request = NetworkEngineRequest(\n",
           count=2)

    # Ghost mode, per chat. These are all the places in the pinned commit that send the
    # methods (grep "functions.messages.readHistory" etc.); each catches the error.
    read = "readReceipts"
    ghost(t, "ghost-read-secret", "State/SynchronizePeerReadState.swift", "messages.readEncryptedHistory", read, "peerId")
    ghost(t, "ghost-read-channel", "State/SynchronizePeerReadState.swift", "channels.readHistory", read, "peerId")
    ghost(t, "ghost-read-history", "State/SynchronizePeerReadState.swift", "messages.readHistory", read, "peerId")
    ghost(t, "ghost-read-all-channels", "TelegramEngine/Messages/MarkAllChatsAsRead.swift", "channels.readHistory", read, "peerId")
    ghost(t, "ghost-read-all-chats", "TelegramEngine/Messages/MarkAllChatsAsRead.swift", "messages.readHistory", read, "peerId")
    ghost(t, "ghost-read-discussion", "TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift", "messages.readDiscussion", read, "peerId", count=3)
    ghost(t, "ghost-read-thread", "TelegramEngine/Messages/ReplyThreadHistory.swift", "messages.readDiscussion", read, "peerId")
    ghost(t, "ghost-contents-live", "State/AccountViewTracker.swift", "messages.readMessageContents", read, "peerId")
    ghost(t, "ghost-contents-live-channel", "State/AccountViewTracker.swift", "channels.readMessageContents", read, "peerId")
    ghost(t, "ghost-contents-mentions", "State/ManagedConsumePersonalMessagesActions.swift", "messages.readMessageContents", read, "id.peerId", count=2)
    ghost(t, "ghost-contents-mentions-channel", "State/ManagedConsumePersonalMessagesActions.swift", "channels.readMessageContents", read, "id.peerId", count=2)
    ghost(t, "ghost-contents", "State/ManagedSynchronizeConsumeMessageContentsOperations.swift", "messages.readMessageContents", read, "peerId")
    ghost(t, "ghost-contents-channel", "State/ManagedSynchronizeConsumeMessageContentsOperations.swift", "channels.readMessageContents", read, "peerId")
    ghost(t, "ghost-contents-unseen", "State/ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations.swift", "messages.readMessageContents", read, "peerId")
    ghost(t, "ghost-contents-unseen-channel", "State/ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations.swift", "channels.readMessageContents", read, "peerId")
    ghost(t, "ghost-typing", "State/ManagedLocalInputActivities.swift", "messages.setTyping", "typing", "peerId")
    ghost(t, "ghost-typing-secret", "State/ManagedLocalInputActivities.swift", "messages.setEncryptedTyping", "typing", "peerId")
    ghost(t, "ghost-typing-draft", "State/TypingDraftStop.swift", "messages.setTyping", "typing", "peerId")
    ghost(t, "ghost-stories-read", "State/ManagedSynchronizeViewStoriesOperations.swift", "stories.readStories", "storyViews", "peer.id")
    ghost(t, "ghost-stories-views", "TelegramEngine/Messages/Stories.swift", "stories.incrementStoryViews", "storyViews", "peerId")

    # "Online" pings become "offline" pings, which also cancel the online status the server
    # sets after you send a message.
    t.edit("ghost-online", CORE + "State/ManagedAccountPresence.swift",
           "request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse))\n",
           "request = self.network.request(Api.functions.account.updateStatus(offline: IlvGhost.reportsOffline ? .boolTrue : .boolFalse))\n")


def message_keeping(t: Tree):
    # Deleted by the other side: keep the message, remember it as deleted.
    f = CORE + "State/AccountStateManagementUtils.swift"
    t.edit("keep-deleted-global", f,
           "            case let .DeleteMessagesWithGlobalIds(ids):\n",
           "            case let .DeleteMessagesWithGlobalIds(ids) where IlvPrivacy.isEnabled(.keepDeletedMessages):\n"
           "                ilvKeepDeletedMessages(transaction: transaction, globalIds: ids)\n"
           "            case let .DeleteMessagesWithGlobalIds(ids):\n")
    t.edit("keep-deleted", f,
           "            case let .DeleteMessages(ids):\n"
           "                _internal_deleteMessages(",
           "            case let .DeleteMessages(ids) where IlvPrivacy.isEnabled(.keepDeletedMessages):\n"
           "                ilvKeepDeletedMessages(transaction: transaction, ids: ids)\n"
           "            case let .DeleteMessages(ids):\n"
           "                _internal_deleteMessages(")

    # Self-destruct timers: drop the timer instead of deleting the message / expiring media.
    t.edit("keep-self-destructing", CORE + "State/ManagedAutoremoveMessageOperations.swift",
           "                    if let message = transaction.getMessage(entry.messageId) {\n"
           "                        if message.id.peerId.namespace == Namespaces.Peer.SecretChat || isRemove {\n",
           "                    if transaction.getMessage(entry.messageId) != nil, IlvPrivacy.isEnabled(.keepSelfDestructing) {\n"
           "                        transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: tag)\n"
           "                    } else if let message = transaction.getMessage(entry.messageId) {\n"
           "                        if message.id.peerId.namespace == Namespaces.Peer.SecretChat || isRemove {\n")

    # View-once: opening the media does not consume it, so no timer starts and the sender is
    # not told it was opened.
    t.edit("replay-view-once", CORE + "TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift",
           "        if let message = transaction.getMessage(messageId), message.flags.contains(.Incoming) {\n"
           "            var updateMessage = false\n",
           "        if let message = transaction.getMessage(messageId), message.flags.contains(.Incoming) {\n"
           "            if ilvSkipsConsumption(message) {\n"
           "                return\n"
           "            }\n"
           "            var updateMessage = false\n")

    # "deleted 12:34" next to kept messages.
    t.edit("deleted-label", "submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode/Sources/StringForMessageTimestampStatus.swift",
           "public func stringForMessageTimestampStatus(\n",
           "public func stringForMessageTimestampStatus(\n"
           "    context: AccountContext,\n"
           "    message: EngineMessage,\n"
           "    dateTimeFormat: PresentationDateTimeFormat,\n"
           "    nameDisplayOrder: PresentationPersonNameOrder,\n"
           "    strings: PresentationStrings,\n"
           "    format: MessageTimestampStatusFormat = .regular,\n"
           "    associatedData: ChatMessageItemAssociatedData,\n"
           "    ignoreAuthor: Bool = false\n"
           ") -> String {\n"
           "    let result = ilvOriginalStringForMessageTimestampStatus(context: context, message: message, dateTimeFormat: dateTimeFormat, nameDisplayOrder: nameDisplayOrder, strings: strings, format: format, associatedData: associatedData, ignoreAuthor: ignoreAuthor)\n"
           "    if IlvDeletedMessages.contains(message.id) {\n"
           "        return ((Locale.preferredLanguages.first ?? \"\").hasPrefix(\"ru\") ? \"удалено \" : \"deleted \") + result\n"
           "    }\n"
           "    return result\n"
           "}\n"
           "\n"
           "private func ilvOriginalStringForMessageTimestampStatus(\n")


def media_privacy(t: Tree):
    # Voice messages: pitch-shift every 20 ms packet before it reaches the Opus encoder.
    f = "submodules/TelegramUI/Sources/ManagedAudioRecorder.swift"
    t.edit("voice-changer-state", f,
           "    private var micLevelPeak: Int16 = 0\n",
           "    private var micLevelPeak: Int16 = 0\n"
           "    private let ilvVoiceChanger = IlvVoiceChanger.makeIfEnabled(sampleRate: 48000.0)\n")
    t.edit("voice-changer", f,
           "                self.processWaveformPreview(samples: currentEncoderPacket.assumingMemoryBound(to: Int16.self), count: currentEncoderPacketSize / 2)\n",
           "                self.ilvVoiceChanger?.process(currentEncoderPacket.assumingMemoryBound(to: Int16.self), count: currentEncoderPacketSize / 2)\n"
           "                self.processWaveformPreview(samples: currentEncoderPacket.assumingMemoryBound(to: Int16.self), count: currentEncoderPacketSize / 2)\n")

    # Video messages: blur faces / change voice in each finished segment before it is shown or
    # sent. Live upload would stream the unprocessed recording, so it is off while processing.
    d = "submodules/TelegramUI/Components/VideoMessageCameraScreen/Sources/"
    t.copy("video-message-processor", ROOT / "src/VideoMessageCameraScreen/IlvVideoMessageProcessor.swift",
           d + "IlvVideoMessageProcessor.swift")
    f = d + "VideoMessageCameraScreen.swift"
    t.edit("video-message-no-live-upload", f,
           "            guard let controller = self.controller, controller.allowLiveUpload, self.liveUploadInterface == nil else {\n",
           "            guard let controller = self.controller, controller.allowLiveUpload, !ilvVideoMessageProcessingEnabled, self.liveUploadInterface == nil else {\n")
    t.edit("video-message-process", f,
           "            self.completion.connect { [weak self] result in\n"
           "                if let self {\n"
           "                    self.addCaptureResult(result)\n"
           "                }\n"
           "            }\n",
           "            self.completion.connect { [weak self] result in\n"
           "                ilvProcessVideoMessageResult(result, completion: { [weak self] processed in\n"
           "                    if let self {\n"
           "                        self.addCaptureResult(processed)\n"
           "                    }\n"
           "                })\n"
           "            }\n")


def chat_ui(t: Tree):
    t.copy("chat-ghost-button-source", ROOT / "src/TelegramUI/IlvChatGhostButton.swift",
           "submodules/TelegramUI/Sources/Ilv/IlvChatGhostButton.swift")
    signature = ("func secondaryRightNavigationButtonForChatInterfaceState(context: AccountContext, "
                 "presentationInterfaceState: ChatPresentationInterfaceState, strings: PresentationStrings, "
                 "currentButton: ChatNavigationButton?, target: Any?, selector: Selector?, "
                 "chatInfoNavigationButton: ChatNavigationButton?, moreInfoNavigationButton: ChatNavigationButton?) "
                 "-> ChatNavigationButton? {\n")
    t.edit("chat-ghost-button", "submodules/TelegramUI/Sources/ChatInterfaceStateNavigationButtons.swift",
           signature,
           signature +
           "    if let ilvButton = ilvGhostNavigationButton(context: context, presentationInterfaceState: presentationInterfaceState, currentButton: currentButton, target: target) {\n"
           "        return ilvButton\n"
           "    }\n")

    # The ilvtg settings tab, between Chats and Settings.
    f = "submodules/TelegramUI/Sources/TelegramRootController.swift"
    t.edit("tab-property", f,
           "    public var accountSettingsController: PeerInfoScreen?\n",
           "    public var accountSettingsController: PeerInfoScreen?\n"
           "    private var ilvTabController: ViewController?\n")
    t.edit("tab-add", f,
           "        accountSettingsController.parentController = self\n"
           "        controllers.append(accountSettingsController)\n",
           "        accountSettingsController.parentController = self\n"
           "        let ilvTab = ilvSettingsTabController(context: self.context)\n"
           "        self.ilvTabController = ilvTab\n"
           "        controllers.append(ilvTab)\n"
           "        controllers.append(accountSettingsController)\n")
    t.edit("tab-update", f,
           "        controllers.append(self.accountSettingsController!)\n",
           "        if let ilvTab = self.ilvTabController {\n"
           "            controllers.append(ilvTab)\n"
           "        }\n"
           "        controllers.append(self.accountSettingsController!)\n")


def privacy_defaults(t: Tree):
    # Contacts are not uploaded unless the user turns sync on (Privacy → Data Settings).
    t.edit("contacts-default", "submodules/TelegramCore/Sources/SyncCore/SyncCore_ContactsSettings.swift",
           "        return ContactsSettings(synchronizeContacts: true)\n",
           "        return ContactsSettings(synchronizeContacts: false)\n")
    t.edit("contacts-after-login", "submodules/TelegramCore/Sources/State/InitializeAccountAfterLogin.swift",
           "        return PreferencesEntry(ContactsSettings(synchronizeContacts: syncContacts))\n",
           "        return PreferencesEntry(ContactsSettings(synchronizeContacts: false))\n")
    t.edit("contacts-legacy-default", "submodules/TelegramUIPreferences/Sources/ContactSynchronizationSettings.swift",
           "ContactSynchronizationSettings(_legacySynchronizeDeviceContacts: true,",
           "ContactSynchronizationSettings(_legacySynchronizeDeviceContacts: false,")

    # CallKit writes every call into the iOS Recents list, which iCloud syncs across devices.
    t.edit("callkit-default", "submodules/TelegramUIPreferences/Sources/VoiceCallSettings.swift",
           "        return VoiceCallSettings(dataSaving: .default, enableSystemIntegration: true)\n",
           "        return VoiceCallSettings(dataSaving: .default, enableSystemIntegration: false)\n")

    # Siri / Spotlight / share-sheet suggestions: chats and contacts are not donated to iOS.
    t.edit("intents-default", "submodules/TelegramUIPreferences/Sources/IntentsSettings.swift",
           "IntentsSettings(initiallyReset: false, account: nil, contacts: true, privateChats: false, savedMessages: true, groups: false, onlyShared: false)",
           "IntentsSettings(initiallyReset: false, account: nil, contacts: false, privateChats: false, savedMessages: false, groups: false, onlyShared: true)")
    t.edit("notification-donation", "Telegram/NotificationService/Sources/NotificationService.swift",
           "                interaction.donate(completion: nil)\n",
           "                // ilvtg: incoming messages are not donated to Siri.\n")

    # Mobile data: smaller automatic downloads on cellular (Wi-Fi keeps upstream behaviour).
    t.edit("cellular-autodownload", "submodules/TelegramUIPreferences/Sources/MediaAutoDownloadSettings.swift",
           "cellular: MediaAutoDownloadConnection(enabled: true, preset: .medium, custom: nil)",
           "cellular: MediaAutoDownloadConnection(enabled: true, preset: .low, custom: nil)")


def settings_screen(t: Tree):
    # The ilvtg settings screen: a tab of its own (chat_ui) and a row in Privacy and Security.
    t.copy("privacy-screen", ROOT / "src/SettingsUI/IlvPrivacyController.swift",
           "submodules/SettingsUI/Sources/Ilv/IlvPrivacyController.swift")

    f = "submodules/SettingsUI/Sources/Privacy and Security/PrivacyAndSecurityController.swift"
    t.edit("pas-argument", f,
           "    let openGiftsPrivacy: () -> Void\n",
           "    let openGiftsPrivacy: () -> Void\n"
           "    var openIlvPrivacy: () -> Void = {}\n")
    t.edit("pas-section", f,
           "private enum PrivacyAndSecuritySection: Int32 {\n    case general\n",
           "private enum PrivacyAndSecuritySection: Int32 {\n    case ilvtg\n    case general\n")
    t.edit("pas-case", f,
           "    case openLinksIn(PresentationTheme, String, String)\n",
           "    case openLinksIn(PresentationTheme, String, String)\n"
           "    case ilvPrivacy(PresentationTheme, String)\n")
    t.edit("pas-section-map", f,
           "        case .openLinksIn:\n            return PrivacyAndSecuritySection.linkHandling.rawValue\n",
           "        case .openLinksIn:\n            return PrivacyAndSecuritySection.linkHandling.rawValue\n"
           "        case .ilvPrivacy:\n            return PrivacyAndSecuritySection.ilvtg.rawValue\n")
    t.edit("pas-stable-id", f,
           "            case .blockedPeers:\n                return 1\n",
           "            case .ilvPrivacy:\n                return 0\n"
           "            case .blockedPeers:\n                return 1\n")
    t.edit("pas-equality", f,
           "            case let .openLinksIn(lhsTheme, lhsText, lhsValue):\n",
           "            case let .ilvPrivacy(lhsTheme, lhsText):\n"
           "                if case let .ilvPrivacy(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {\n"
           "                    return true\n"
           "                } else {\n"
           "                    return false\n"
           "                }\n"
           "            case let .openLinksIn(lhsTheme, lhsText, lhsValue):\n")
    t.edit("pas-item", f,
           "            case let .openLinksIn(_, text, value):\n",
           "            case let .ilvPrivacy(_, text):\n"
           "                return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, label: \"\", sectionId: self.section, style: .blocks, action: {\n"
           "                    arguments.openIlvPrivacy()\n"
           "                })\n"
           "            case let .openLinksIn(_, text, value):\n")
    t.edit("pas-entry", f,
           "    entries.append(.blockedPeers(",
           "    entries.append(.ilvPrivacy(presentationData.theme, (Locale.preferredLanguages.first ?? \"\").hasPrefix(\"ru\") ? \"Приватность ilvtg\" : \"ilvtg Privacy\"))\n"
           "    entries.append(.blockedPeers(")
    t.edit("pas-open", f,
           "    pushControllerImpl = { [weak controller] c, animated in\n",
           "    arguments.openIlvPrivacy = {\n"
           "        pushControllerImpl?(ilvPrivacyController(context: context), true)\n"
           "    }\n"
           "    pushControllerImpl = { [weak controller] c, animated in\n")


def sideload_compat(t: Tree):
    # Sideloading tools re-sign the app, often without the App Group entitlement. Upstream then
    # stops launching before the window is shown ("Error 2" on a hidden window = black screen).
    # The main app does not need a shared container without extensions: fall back to a private
    # directory inside the app sandbox, excluded from iCloud backup.
    f = "submodules/TelegramUI/Sources/AppDelegate.swift"
    t.edit("container-fallback", f,
           "        let maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)\n",
           "        let maybeAppGroupUrl: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) ?? { () -> URL? in\n"
           "            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {\n"
           "                return nil\n"
           "            }\n"
           "            var url = base.appendingPathComponent(\"ilvtg-container\", isDirectory: true)\n"
           "            guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)) != nil else {\n"
           "                return nil\n"
           "            }\n"
           "            var values = URLResourceValues()\n"
           "            values.isExcludedFromBackup = true\n"
           "            _ = try? url.setResourceValues(values)\n"
           "            return url\n"
           "        }()\n")
    t.edit("visible-launch-error", f,
           "            self.mainWindow?.presentNative(UIAlertController(title: nil, message: \"Error 2\", preferredStyle: .alert))\n",
           "            self.window?.makeKeyAndVisible()\n"
           "            self.mainWindow?.presentNative(UIAlertController(title: nil, message: \"Error 2: no writable data container\", preferredStyle: .alert))\n")


def branding(t: Tree, app: dict):
    name = app["display_name"]
    if not name or "<" in name or "&" in name:
        raise SystemExit("[ilvtg] app.json display_name must be plain text")
    t.edit("display-name", "Telegram/BUILD",
           "    <key>CFBundleDisplayName</key>\n    <string>Telegram</string>\n",
           f"    <key>CFBundleDisplayName</key>\n    <string>{name}</string>\n",
           count=2)


def build_tweaks(t: Tree, app: dict):
    # dSYMs are only useful for symbolicating crash reports we never collect.
    t.edit("no-dsym", "build-system/Make/Make.py",
           "                # Generate DSYM files when building.\n"
           "                '--apple_generate_dsym',\n"
           "\n"
           "                # Require DSYM files as build output.\n"
           "                '--output_groups=+dsyms',\n",
           "")
    flags = [
        "build --//Telegram:disableProvisioningProfiles",
        "build --features=ilvtg_unsigned",
        "build --features=disable_legacy_signing",
    ]
    if not app.get("app_extensions", False):
        # Share/notification/widget/Siri extensions: pushes cannot reach a self-built app anyway,
        # and every extension is one more App ID to sign when sideloading.
        flags.append("build --//Telegram:disableExtensions")
    t.append("bazelrc", ".bazelrc", "\n# ilvtg\n" + "\n".join(flags) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--no-git-check", action="store_true", help="for an unpacked archive instead of a git checkout")
    parser.add_argument("--dry-run", action="store_true", help="check that every edit matches without writing anything")
    args = parser.parse_args()
    source = args.source.resolve()

    pin = json.loads((ROOT / "upstream.json").read_text(encoding="utf-8"))
    app = json.loads((ROOT / "app.json").read_text(encoding="utf-8"))

    if not args.no_git_check:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        if head != pin["commit"]:
            raise SystemExit(f"[ilvtg] upstream is at {head}, upstream.json pins {pin['commit']}")
    marker = source / ".ilvtg-applied"
    if marker.exists():
        raise SystemExit("[ilvtg] changes are already applied to this tree")

    t = Tree(source, dry_run=args.dry_run)
    privacy_layer(t)
    message_keeping(t)
    media_privacy(t)
    privacy_defaults(t)
    settings_screen(t)
    chat_ui(t)
    sideload_compat(t)
    branding(t, app)
    build_tweaks(t, app)

    if args.dry_run:
        print(f"[ilvtg] dry run: all {len(t.applied)} changes match, nothing written")
        return
    marker.write_text(pin["commit"] + "\n", encoding="utf-8")
    print(f"[ilvtg] applied {len(t.applied)} changes to {pin['commit']}:")
    for name in t.applied:
        print("  - " + name)


if __name__ == "__main__":
    main()
