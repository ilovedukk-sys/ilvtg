#!/usr/bin/env python3
"""Turn a pristine Telegram-iOS checkout (pinned in upstream.json) into ilvtg.

Every change is an exact-text edit with an expected match count. If upstream code drifts and an
anchor no longer matches, the script stops with the file and the edit name instead of producing
a build that silently lacks a privacy change.
"""
import argparse
import json
import os
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

    def replace_region(self, name: str, relpath: str, start: str, end: str, new: str):
        """Replaces the text from `start` (inclusive) up to `end` (exclusive); both anchors must
        occur exactly once."""
        text = self._read(relpath)
        for anchor in (start, end):
            found = text.count(anchor)
            if found != 1:
                raise SystemExit(f"[ilvtg] edit '{name}': expected 1 match of an anchor in {relpath}, found {found}")
        begin = text.index(start)
        finish = text.index(end)
        if finish < begin:
            raise SystemExit(f"[ilvtg] edit '{name}': anchors out of order in {relpath}")
        self._write(relpath, text[:begin] + new + text[finish:])
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
    for name in ["IlvPrivacy", "IlvVoice", "IlvChatExport", "IlvAyuFeatures"]:
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
           "            ilvNoteRequest(data.0.name, network: self)\n"
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

    # Tab bar settings: Contacts tab can be hidden; changes apply at once.
    t.copy("tabs-refresh-source", ROOT / "src/TelegramUI/IlvRootTabs.swift",
           "submodules/TelegramUI/Sources/Ilv/IlvRootTabs.swift")
    f = "submodules/TelegramUI/Sources/TelegramRootController.swift"
    t.edit("tabs-property", f,
           "    public var accountSettingsController: PeerInfoScreen?\n",
           "    public var accountSettingsController: PeerInfoScreen?\n"
           "    private var ilvTabsDisposable: Disposable?\n")
    t.edit("tabs-contacts-add", f,
           "        controllers.append(contactsController)\n",
           "        if !IlvTabs.hideContacts {\n"
           "            controllers.append(contactsController)\n"
           "        }\n")
    t.edit("tabs-observe", f,
           "        accountSettingsController.parentController = self\n"
           "        controllers.append(accountSettingsController)\n",
           "        accountSettingsController.parentController = self\n"
           "        if self.ilvTabsDisposable == nil {\n"
           "            self.ilvTabsDisposable = (IlvTabs.changed\n"
           "            |> deliverOnMainQueue).start(next: { [weak self] _ in\n"
           "                self?.ilvRefreshTabs()\n"
           "            })\n"
           "        }\n"
           "        controllers.append(accountSettingsController)\n")
    t.edit("tabs-contacts-update", f,
           "        controllers.append(self.contactsController!)\n",
           "        if !IlvTabs.hideContacts {\n"
           "            controllers.append(self.contactsController!)\n"
           "        }\n")
    t.edit("tabs-titles", "submodules/TelegramUI/Components/TabBarComponent/Sources/TabBarComponent.swift",
           "                        showsTitle: !component.isCompact,\n",
           "                        showsTitle: !component.isCompact && !UserDefaults.standard.bool(forKey: \"ilvtg.tabs.hideTitles\"),\n",
           count=2)


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
    t.copy("settings-hero", ROOT / "src/SettingsUI/IlvSettingsHeroItem.swift",
           "submodules/SettingsUI/Sources/Ilv/IlvSettingsHeroItem.swift")

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


def settings_row(t: Tree):
    # "ilvtg" row in the main Settings list (first row of the notifications/privacy group).
    d = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/"
    t.edit("settings-row", d + "PeerInfoSettingsItems.swift",
           "    items[.advanced]!.append(PeerInfoScreenDisclosureItem(id: 0, label: notificationsWarning",
           "    items[.advanced]!.append(PeerInfoScreenDisclosureItem(id: 100, text: \"ilvtg\", icon: ilvSettingsRowIcon, action: {\n"
           "        interaction.openSettings(.ilvtg)\n"
           "    }))\n"
           "    items[.advanced]!.append(PeerInfoScreenDisclosureItem(id: 0, label: notificationsWarning")
    t.edit("settings-row-section", d + "PeerInfoScreen.swift",
           "    case ton\n    case wallet\n}\n",
           "    case ton\n    case wallet\n    case ilvtg\n}\n")
    t.edit("settings-row-open", d + "PeerInfoScreenSettingsActions.swift",
           "        case .wallet:\n            guard WalletConfiguration",
           "        case .ilvtg:\n"
           "            push(ilvPrivacyController(context: self.context))\n"
           "        case .wallet:\n            guard WalletConfiguration")


def profile(t: Tree):
    d = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/"
    t.copy("profile-source", ROOT / "src/PeerInfoScreen/IlvProfile.swift", d + "IlvProfile.swift")
    f = d + "PeerInfoProfileItems.swift"

    # ID row at the end of the main section.
    t.edit("profile-id", f,
           "    var result: [(AnyHashable, [PeerInfoScreenItem])] = []\n"
           "    for section in InfoSection.allCases {\n",
           "    if let ilvIdItem = ilvPeerIdItem(data: data, presentationData: presentationData, interaction: interaction) {\n"
           "        items[.peerInfo]!.append(ilvIdItem)\n"
           "    }\n"
           "    var result: [(AnyHashable, [PeerInfoScreenItem])] = []\n"
           "    for section in InfoSection.allCases {\n")

    # Streamer mode: phone numbers and usernames are dots until tapped.
    t.edit("streamer-phone", f,
           "PeerInfoScreenLabeledValueItem(id: ItemPhoneNumber, label: label, text: formattedPhone, textColor: .accent, action: { node, progress in\n"
           "                interaction.openPhone(phone, node, nil, progress)\n",
           "PeerInfoScreenLabeledValueItem(id: ItemPhoneNumber, label: label, text: IlvStreamer.text(formattedPhone), textColor: .accent, action: { node, progress in\n"
           "                if IlvStreamer.reveal(formattedPhone, interaction: interaction) {\n"
           "                    return\n"
           "                }\n"
           "                interaction.openPhone(phone, node, nil, progress)\n")
    t.edit("streamer-username", f,
           "                    label: presentationData.strings.Profile_Username,\n"
           "                    text: \"@\\(mainUsername)\",\n"
           "                    additionalText: additionalUsernames,\n"
           "                    textColor: .accent,\n"
           "                    icon: .qrCode,\n"
           "                    action: { _, progress in\n"
           "                        interaction.openUsername(mainUsername, true, progress)\n",
           "                    label: presentationData.strings.Profile_Username,\n"
           "                    text: IlvStreamer.text(\"@\\(mainUsername)\"),\n"
           "                    additionalText: IlvStreamer.optionalText(additionalUsernames),\n"
           "                    textColor: .accent,\n"
           "                    icon: .qrCode,\n"
           "                    action: { _, progress in\n"
           "                        if IlvStreamer.reveal(\"@\\(mainUsername)\", interaction: interaction) {\n"
           "                            return\n"
           "                        }\n"
           "                        interaction.openUsername(mainUsername, true, progress)\n")
    t.edit("streamer-header", d + "PeerInfoHeaderNode.swift",
           "                    subtitle = \"\\(subtitle) • @\\(mainUsername)\"\n"
           "                }\n"
           "                subtitleStringText = subtitle\n",
           "                    subtitle = \"\\(subtitle) • @\\(mainUsername)\"\n"
           "                }\n"
           "                subtitleStringText = IlvStreamer.text(subtitle)\n")


def location_emulation(t: Tree):
    # Every location the app takes from the device (live location, "current location").
    f = "submodules/DeviceLocationManager/Sources/DeviceLocationManager.swift"
    t.edit("location-push", f,
           "        if let currentLocation = self.currentLocation {\n"
           "            updated(currentLocation, self.currentHeading?.magneticHeading)\n",
           "        if let currentLocation = ilvEmulatedLocation(self.currentLocation) {\n"
           "            updated(currentLocation, self.currentHeading?.magneticHeading)\n")
    t.edit("location-updates", f,
           "        if let location = locations.first {\n",
           "        if let location = ilvEmulatedLocation(locations.first) {\n")
    t.append("location-helper", f,
             "\n"
             "/// ilvtg: location emulation. TelegramCore's IlvLocationEmulation writes these keys.\n"
             "func ilvEmulatedLocation(_ location: CLLocation?) -> CLLocation? {\n"
             "    let defaults = UserDefaults.standard\n"
             "    guard defaults.bool(forKey: \"ilvtg.location.enabled\") else {\n"
             "        return location\n"
             "    }\n"
             "    let coordinate = CLLocationCoordinate2D(latitude: defaults.double(forKey: \"ilvtg.location.lat\"), longitude: defaults.double(forKey: \"ilvtg.location.lon\"))\n"
             "    return CLLocation(coordinate: coordinate, altitude: location?.altitude ?? 0.0, horizontalAccuracy: 10.0, verticalAccuracy: -1.0, timestamp: Date())\n"
             "}\n")

    # The location picker: an "Emulate location here" row under "Send my current location".
    d = "submodules/LocationUI/Sources/"
    t.copy("location-picker-source", ROOT / "src/LocationUI/IlvLocation.swift", d + "IlvLocation.swift")
    t.edit("location-interaction", d + "LocationPickerController.swift",
           "    let showPlacesInThisArea: () -> Void\n",
           "    let showPlacesInThisArea: () -> Void\n"
           "    var ilvToggleEmulation: () -> Void = {}\n")
    f = d + "LocationPickerControllerNode.swift"
    t.edit("location-entry-id", f,
           "    case liveLocation\n    case header\n",
           "    case liveLocation\n    case ilvEmulation\n    case header\n")
    t.edit("location-entry", f,
           "    case liveLocation(PresentationTheme, String, String, CLLocationCoordinate2D?)\n",
           "    case liveLocation(PresentationTheme, String, String, CLLocationCoordinate2D?)\n"
           "    case ilvEmulation(PresentationTheme, String, String)\n")
    t.edit("location-entry-stable-id", f,
           "        case .liveLocation:\n            return .liveLocation\n",
           "        case .liveLocation:\n            return .liveLocation\n"
           "        case .ilvEmulation:\n            return .ilvEmulation\n")
    t.edit("location-entry-equal", f,
           "            case let .header(lhsTheme, lhsTitle):\n",
           "            case let .ilvEmulation(lhsTheme, lhsTitle, lhsSubtitle):\n"
           "                if case let .ilvEmulation(rhsTheme, rhsTitle, rhsSubtitle) = rhs, lhsTheme === rhsTheme, lhsTitle == rhsTitle, lhsSubtitle == rhsSubtitle {\n"
           "                    return true\n"
           "                } else {\n"
           "                    return false\n"
           "                }\n"
           "            case let .header(lhsTheme, lhsTitle):\n")
    t.replace_region("location-entry-order", f,
                     "    static func <(lhs: LocationPickerEntry, rhs: LocationPickerEntry) -> Bool {\n",
                     "    func item(engine: TelegramEngine, presentationData: PresentationData, interaction: LocationPickerInteraction?) -> ListViewItem {\n",
                     "    static func <(lhs: LocationPickerEntry, rhs: LocationPickerEntry) -> Bool {\n"
                     "        let lhsRank = lhs.ilvRank\n"
                     "        let rhsRank = rhs.ilvRank\n"
                     "        if lhsRank != rhsRank {\n"
                     "            return lhsRank < rhsRank\n"
                     "        }\n"
                     "        if case let .venue(_, _, _, _, lhsIndex) = lhs, case let .venue(_, _, _, _, rhsIndex) = rhs {\n"
                     "            return lhsIndex < rhsIndex\n"
                     "        }\n"
                     "        return false\n"
                     "    }\n"
                     "\n"
                     "    private var ilvRank: Int {\n"
                     "        switch self {\n"
                     "        case .city:\n"
                     "            return 0\n"
                     "        case .location:\n"
                     "            return 1\n"
                     "        case .liveLocation:\n"
                     "            return 2\n"
                     "        case .ilvEmulation:\n"
                     "            return 3\n"
                     "        case .header:\n"
                     "            return 4\n"
                     "        case .venue:\n"
                     "            return 5\n"
                     "        case .attribution:\n"
                     "            return 6\n"
                     "        }\n"
                     "    }\n"
                     "    \n")
    t.edit("location-entry-item", f,
           "            case let .header(_, title):\n"
           "                return LocationSectionHeaderItem(",
           "            case let .ilvEmulation(_, title, subtitle):\n"
           "                return LocationActionListItem(presentationData: ItemListPresentationData(presentationData), engine: engine, title: title, subtitle: subtitle, icon: .location, beginTimeAndTimeout: nil, action: {\n"
           "                    interaction?.ilvToggleEmulation()\n"
           "                })\n"
           "            case let .header(_, title):\n"
           "                return LocationSectionHeaderItem(")
    t.edit("location-user-location", f,
           "        let userLocation: Signal<CLLocation?, NoError> = self.headerNode.mapNode.userLocation\n",
           "        interaction.ilvToggleEmulation = { [weak self] in\n"
           "            ilvToggleLocationEmulation(coordinate: self?.headerNode.mapNode.mapCenterCoordinate)\n"
           "        }\n"
           "        let userLocation: Signal<CLLocation?, NoError> = ilvEmulatedUserLocation(self.headerNode.mapNode.userLocation)\n")
    t.edit("location-entry-add", f,
           "                entries.append(.header(presentationData.theme, presentationData.strings.Map_ChooseAPlace.uppercased()))\n",
           "                if case .share = mode, source == .generic {\n"
           "                    entries.append(.ilvEmulation(presentationData.theme, ilvLocationEmulationTitle(), ilvLocationEmulationSubtitle()))\n"
           "                }\n"
           "                entries.append(.header(presentationData.theme, presentationData.strings.Map_ChooseAPlace.uppercased()))\n")


def appearance(t: Tree):
    # Cherry accent for the built-in themes.
    t.copy("cherry-accent-source", ROOT / "src/TelegramPresentationData/IlvAccent.swift",
           "submodules/TelegramPresentationData/Sources/IlvAccent.swift")
    t.edit("cherry-accent", "submodules/TelegramPresentationData/Sources/MakePresentationTheme.swift",
           "            theme = customizePresentationTheme(defaultTheme, editing: true, accentColor: accentColor, outgoingAccentColor: outgoingAccentColor, backgroundColors: backgroundColors, bubbleColors: bubbleColors, animateBubbleColors: animateBubbleColors, wallpaper: wallpaper, baseColor: baseColor)\n",
           "            theme = customizePresentationTheme(defaultTheme, editing: true, accentColor: ilvAccentColor(accentColor, reference: reference), outgoingAccentColor: outgoingAccentColor, backgroundColors: backgroundColors, bubbleColors: bubbleColors, animateBubbleColors: animateBubbleColors, wallpaper: wallpaper, baseColor: baseColor)\n")

    # Message bubble transparency.
    f = "submodules/ChatMessageBackground/Sources/ChatMessageBackground.swift"
    t.edit("bubble-alpha-outline", f,
           "        self.addSubnode(self.outlineImageNode)\n",
           "        self.addSubnode(self.outlineImageNode)\n"
           "        self.outlineImageNode.alpha = CGFloat(ilvBubbleAlpha())\n")
    t.edit("bubble-alpha-image", f,
           "        imageView.image = self.imageViewImage\n",
           "        imageView.image = self.imageViewImage\n"
           "        imageView.alpha = CGFloat(ilvBubbleAlpha())\n")
    t.edit("bubble-alpha-backdrop", f,
           "                        self.insertSubnode(backgroundContent, at: 0)\n",
           "                        backgroundContent.alpha = CGFloat(ilvBubbleAlpha())\n"
           "                        self.insertSubnode(backgroundContent, at: 0)\n",
           count=2)
    t.append("bubble-alpha-helper", f,
             "\n"
             "/// ilvtg: opacity of message bubbles. TelegramCore's IlvAppearance writes this key.\n"
             "func ilvBubbleAlpha() -> Double {\n"
             "    let value = UserDefaults.standard.double(forKey: \"ilvtg.bubbleAlpha\")\n"
             "    return value > 0.0 ? min(1.0, value) : 1.0\n"
             "}\n")


def fake_passcode(t: Tree):
    # A wrong passcode that matches the fake one wipes the accounts and opens the (now empty) app.
    t.edit("fake-passcode", "submodules/PasscodeUI/Sources/PasscodeEntryController.swift",
           "                    case .invalidCode:\n"
           "                        self.controllerNode.animateError()\n",
           "                    case .invalidCode:\n"
           "                        if IlvDuress.matches(code) {\n"
           "                            IlvDuress.trigger(accountManager: self.accountManager)\n"
           "                            if self.authenticated == nil && self.completed == nil {\n"
           "                                self.appLockContext.unlock()\n"
           "                                return\n"
           "                            }\n"
           "                        }\n"
           "                        self.controllerNode.animateError()\n")
    # "Delete accounts permanently": account.deleteAccount right before the server logout.
    t.edit("duress-delete", "submodules/TelegramCore/Sources/Account/AccountManager.swift",
           "                account.shouldBeServiceTaskMaster.set(.single(.always))\n"
           "                return account.network.request(Api.functions.auth.logOut())\n",
           "                account.shouldBeServiceTaskMaster.set(.single(.always))\n"
           "                return (ilvDuressBeforeLogout(id: id, network: account.network)\n"
           "                |> castError(MTRpcError.self)\n"
           "                |> mapToSignal { _ -> Signal<Api.auth.LoggedOut, MTRpcError> in\n"
           "                    return account.network.request(Api.functions.auth.logOut())\n"
           "                })\n")


def ayu_features(t: Tree):
    """Ideas from AyuGram, implemented here without any third-party server."""
    core = "submodules/TelegramCore/Sources/"

    # Sending without going online, and forwards from protected chats sent as new messages.
    t.edit("ghost-sending", core + "PendingMessages/EnqueueMessage.swift",
           "public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {\n"
           "    let signal: Signal<[(Bool, EnqueueMessage)], NoError>\n"
           "    if let transformOutgoingMessageMedia = account.transformOutgoingMessageMedia {\n"
           "        signal = opportunisticallyTransformOutgoingMedia(network: account.network, postbox: account.postbox, transformOutgoingMessageMedia: transformOutgoingMessageMedia, messages: messages, userInteractive: true)\n"
           "    } else {\n"
           "        signal = .single(messages.map { (false, $0) })\n"
           "    }\n"
           "    return signal\n"
           "    |> mapToSignal { messages -> Signal<[MessageId?], NoError> in\n",
           "public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {\n"
           "    let signal: Signal<[(Bool, EnqueueMessage)], NoError>\n"
           "    if let transformOutgoingMessageMedia = account.transformOutgoingMessageMedia {\n"
           "        signal = opportunisticallyTransformOutgoingMedia(network: account.network, postbox: account.postbox, transformOutgoingMessageMedia: transformOutgoingMessageMedia, messages: messages, userInteractive: true)\n"
           "    } else {\n"
           "        signal = .single(messages.map { (false, $0) })\n"
           "    }\n"
           "    return signal\n"
           "    |> mapToSignal { messages in ilvPrepareProtectedForwards(account: account, messages: messages) }\n"
           "    |> mapToSignal { messages in ilvPrepareGhostSending(account: account, peerId: peerId, messages: messages) }\n"
           "    |> mapToSignal { messages -> Signal<[MessageId?], NoError> in\n")

    # Edit history: the stored text before a server edit replaces it.
    t.edit("edit-history", core + "State/AccountStateManagementUtils.swift",
           "                    return .update(mergedServerMessageUpdate(previous: previousMessage, updated: message))\n"
           "                })\n"
           "                if let generatedEvent = generatedEvent {\n",
           "                    ilvRecordEdit(previous: previousMessage, updatedText: message.text)\n"
           "                    return .update(mergedServerMessageUpdate(previous: previousMessage, updated: message))\n"
           "                })\n"
           "                if let generatedEvent = generatedEvent {\n")

    # "Restrict saving content" ignored on this device (copy, save, screenshots, sharing).
    t.edit("copy-protection-message", core + "Utils/MessageUtils.swift",
           "    func isCopyProtected() -> Bool {\n"
           "        if self.flags.contains(.CopyProtected) {\n",
           "    func isCopyProtected() -> Bool {\n"
           "        if IlvPrivacy.isEnabled(.ignoreCopyProtection) {\n"
           "            return false\n"
           "        }\n"
           "        if self.flags.contains(.CopyProtected) {\n")
    t.edit("copy-protection-peer", core + "Utils/PeerUtils.swift",
           "    var isCopyProtectionEnabled: Bool {\n"
           "        switch self {\n",
           "    var isCopyProtectionEnabled: Bool {\n"
           "        if IlvPrivacy.isEnabled(.ignoreCopyProtection) {\n"
           "            return false\n"
           "        }\n"
           "        switch self {\n")
    t.edit("copy-protection-data", core + "TelegramEngine/Data/PeersData.swift",
           "                guard let peer = peerViewMainPeer(view) else {\n"
           "                    return false\n"
           "                }\n"
           "                if let cachedPeerData = view.cachedData as? CachedUserData {\n"
           "                    return cachedPeerData.flags.contains(.copyProtectionEnabled)\n",
           "                guard let peer = peerViewMainPeer(view) else {\n"
           "                    return false\n"
           "                }\n"
           "                if IlvPrivacy.isEnabled(.ignoreCopyProtection) {\n"
           "                    return false\n"
           "                }\n"
           "                if let cachedPeerData = view.cachedData as? CachedUserData {\n"
           "                    return cachedPeerData.flags.contains(.copyProtectionEnabled)\n")
    private_chat = "cachedUserData.flags.contains(.copyProtectionEnabled) || cachedUserData.flags.contains(.myCopyProtectionEnabled)"
    bypassed = "!IlvPrivacy.isEnabled(.ignoreCopyProtection) && (" + private_chat + ")"
    t.edit("copy-protection-chat", "submodules/TelegramUI/Sources/ChatControllerContentData.swift",
           "copyProtectionEnabled = " + private_chat + "\n",
           "copyProtectionEnabled = " + bypassed + "\n")
    t.edit("copy-protection-history", "submodules/TelegramUI/Sources/ChatHistoryListNode.swift",
           "isCopyProtectionEnabled = " + private_chat + "\n",
           "isCopyProtectionEnabled = " + bypassed + "\n")
    t.edit("copy-protection-gallery", "submodules/GalleryUI/Sources/GalleryController.swift",
           "return (message, " + private_chat + ")\n",
           "return (message, " + bypassed + ")\n")
    t.edit("copy-protection-profile", "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift",
           "if let cachedUserData = data.cachedData as? CachedUserData, " + private_chat + " {\n",
           "if let cachedUserData = data.cachedData as? CachedUserData, " + bypassed + " {\n")

    # Screenshots are not reported: secret chats and view-once media in cloud chats.
    t.edit("screenshots-secret", core + "SecretChats/SetSecretChatMessageAutoremoveTimeoutInteractively.swift",
           "func _internal_addSecretChatMessageScreenshot(account: Account, peerId: PeerId) -> Signal<Void, NoError> {\n",
           "func _internal_addSecretChatMessageScreenshot(account: Account, peerId: PeerId) -> Signal<Void, NoError> {\n"
           "    if IlvPrivacy.isEnabled(.hideScreenshots) {\n"
           "        return .complete()\n"
           "    }\n")
    t.edit("screenshots-view-once", "submodules/GalleryUI/Sources/SecretMediaPreviewController.swift",
           "                if let strongSelf = self, strongSelf.traceVisibility() {\n"
           "                    if strongSelf.messageId.peerId.namespace == Namespaces.Peer.CloudUser {\n",
           "                if let strongSelf = self, strongSelf.traceVisibility() {\n"
           "                    if IlvPrivacy.isEnabled(.hideScreenshots) {\n"
           "                    } else if strongSelf.messageId.peerId.namespace == Namespaces.Peer.CloudUser {\n")

    # Context menu: edit history and "mark chat as read".
    t.copy("message-context-actions-source", ROOT / "src/TelegramUI/IlvMessageActions.swift",
           "submodules/TelegramUI/Sources/Ilv/IlvMessageActions.swift")
    t.edit("message-context-actions", "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift",
           "        let isCopyProtected = chatPresentationInterfaceState.copyProtectionEnabled || message.isCopyProtected()\n",
           "        actions.append(contentsOf: ilvMessageContextActions(context: context, message: message, controllerInteraction: controllerInteraction))\n"
           "        let isCopyProtected = chatPresentationInterfaceState.copyProtectionEnabled || message.isCopyProtected()\n")


def battery(t: Tree):
    """Battery-saving defaults. They apply to settings the user has not changed; Settings →
    ilvtg → Battery can apply them to existing settings too."""
    f = "submodules/TelegramUIPreferences/Sources/MediaAutoDownloadSettings.swift"
    t.edit("battery-energy-defaults", f,
           "        return EnergyUsageSettings(\n"
           "            activationThreshold: 15,\n"
           "            autoplayVideo: true,\n"
           "            autoplayGif: true,\n"
           "            loopStickers: true,\n"
           "            loopEmoji: isCapable,\n"
           "            fullTranslucency: isCapable,\n"
           "            extendBackgroundWork: true,\n"
           "            autodownloadInBackground: true\n"
           "        )\n",
           "        // ilvtg: videos don't autoplay, stickers and emoji play once, no extended background\n"
           "        // work or background downloads, power saving from 30% battery.\n"
           "        return EnergyUsageSettings(\n"
           "            activationThreshold: 30,\n"
           "            autoplayVideo: false,\n"
           "            autoplayGif: true,\n"
           "            loopStickers: false,\n"
           "            loopEmoji: false,\n"
           "            fullTranslucency: isCapable,\n"
           "            extendBackgroundWork: false,\n"
           "            autodownloadInBackground: false\n"
           "        )\n")
    # Wi-Fi: "medium" instead of "high" (no 10 MB video preloading); nothing downloads in the
    # background. Cellular is set to "low" in privacy_defaults.
    t.edit("battery-autodownload", f,
           "wifi: MediaAutoDownloadConnection(enabled: true, preset: .high, custom: nil), downloadInBackground: true,",
           "wifi: MediaAutoDownloadConnection(enabled: true, preset: .medium, custom: nil), downloadInBackground: false,")


def extras(t: Tree):
    # Confirmation before outgoing calls.
    t.copy("confirm-calls-source", ROOT / "src/TelegramUI/IlvCallConfirm.swift",
           "submodules/TelegramUI/Sources/Ilv/IlvCallConfirm.swift")
    t.edit("confirm-calls", "submodules/TelegramUI/Sources/AccountContext.swift",
           "    public func requestCall(peerId: EnginePeer.Id, isVideo: Bool, completion: @escaping () -> Void) {\n"
           "        guard let callResult = ",
           "    public func requestCall(peerId: EnginePeer.Id, isVideo: Bool, completion: @escaping () -> Void) {\n"
           "        if IlvPrivacy.isEnabled(.confirmCalls) {\n"
           "            ilvConfirmCall(context: self, peerId: peerId, isVideo: isVideo, confirmed: { [weak self] in\n"
           "                self?.ilvPerformRequestCall(peerId: peerId, isVideo: isVideo, completion: completion)\n"
           "            })\n"
           "            return\n"
           "        }\n"
           "        self.ilvPerformRequestCall(peerId: peerId, isVideo: isVideo, completion: completion)\n"
           "    }\n"
           "\n"
           "    func ilvPerformRequestCall(peerId: EnginePeer.Id, isVideo: Bool, completion: @escaping () -> Void) {\n"
           "        guard let callResult = ")

    # Premium, Stars and gift rows hidden in Settings.
    t.edit("hide-premium", "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift",
           "    for section in SettingsSection.allCases {\n"
           "        if let sectionItems = items[section], !sectionItems.isEmpty {\n",
           "    for section in SettingsSection.allCases {\n"
           "        if section == .payment && IlvPrivacy.isEnabled(.hidePremiumPromos) {\n"
           "            continue\n"
           "        }\n"
           "        if let sectionItems = items[section], !sectionItems.isEmpty {\n")


def stories_and_locks(t: Tree, app: dict):
    msgs = "submodules/TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift"
    # Hidden stories: no stories bar and no preloading.
    t.edit("hide-stories", msgs,
           "        public func storySubscriptions(isHidden: Bool, tempKeepNewlyArchived: Bool = false) -> Signal<EngineStorySubscriptions, NoError> {\n",
           "        public func storySubscriptions(isHidden: Bool, tempKeepNewlyArchived: Bool = false) -> Signal<EngineStorySubscriptions, NoError> {\n"
           "            if IlvPrivacy.isEnabled(.hideStories) {\n"
           "                return .single(EngineStorySubscriptions(accountItem: nil, items: [], hasMoreToken: nil))\n"
           "            }\n")
    t.edit("hide-stories-preload", msgs,
           "        public func preloadStorySubscriptions(isHidden: Bool, preferHighQuality: Signal<Bool, NoError>) -> Signal<[EngineMedia.Id: StoryPreloadInfo], NoError> {\n",
           "        public func preloadStorySubscriptions(isHidden: Bool, preferHighQuality: Signal<Bool, NoError>) -> Signal<[EngineMedia.Id: StoryPreloadInfo], NoError> {\n"
           "            if IlvPrivacy.isEnabled(.hideStories) {\n"
           "                return .single([:])\n"
           "            }\n")

    # "Save to Gallery" for anyone's story, without Premium.
    f = "submodules/TelegramUI/Components/Stories/StoryContainerScreen/Sources/StoryItemSetContainerComponent.swift"
    t.edit("download-stories-menu", f,
           "                    } else if !component.slice.item.storyItem.isForwardingDisabled {\n",
           "                    } else if !component.slice.item.storyItem.isForwardingDisabled || IlvPrivacy.isEnabled(.downloadStories) {\n")
    t.edit("download-stories-icon", f,
           "UIImage(bundleImageName: accountUser.isPremium ? \"Chat/Context Menu/Download\" : \"Chat/Context Menu/DownloadLocked\")",
           "UIImage(bundleImageName: (accountUser.isPremium || IlvPrivacy.isEnabled(.downloadStories)) ? \"Chat/Context Menu/Download\" : \"Chat/Context Menu/DownloadLocked\")")
    t.edit("download-stories-save", f,
           "                            if accountUser.isPremium {\n"
           "                                self.requestSave()\n",
           "                            if accountUser.isPremium || IlvPrivacy.isEnabled(.downloadStories) {\n"
           "                                self.requestSave()\n")

    # Locked chats: Face ID / Touch ID / passcode before opening; empty long-press preview.
    t.copy("chat-lock-source", ROOT / "src/TelegramUI/IlvChatLockGate.swift",
           "submodules/TelegramUI/Sources/Ilv/IlvChatLockGate.swift")
    t.edit("chat-lock-open", "submodules/TelegramUI/Sources/NavigateToChatController.swift",
           "public func navigateToChatControllerImpl(_ params: NavigateToChatControllerParams) {\n",
           "public func navigateToChatControllerImpl(_ params: NavigateToChatControllerParams) {\n"
           "    if case let .peer(peer) = params.chatLocation, ilvChatNeedsUnlock(peer.id) {\n"
           "        ilvUnlockChat(peer.id, completion: {\n"
           "            ilvNavigateToChatControllerAfterUnlock(params)\n"
           "        })\n"
           "        return\n"
           "    }\n"
           "    ilvNavigateToChatControllerAfterUnlock(params)\n"
           "}\n"
           "\n"
           "private func ilvNavigateToChatControllerAfterUnlock(_ params: NavigateToChatControllerParams) {\n")
    t.edit("chat-lock-preview", "submodules/TelegramUI/Sources/ChatController.swift",
           "    override public func loadDisplayNode() {\n"
           "        self.loadDisplayNodeImpl()\n",
           "    override public func loadDisplayNode() {\n"
           "        self.loadDisplayNodeImpl()\n"
           "        if case .standard(.previewing) = self.presentationInterfaceState.mode, case let .peer(peerId) = self.chatLocation, ilvChatNeedsUnlock(peerId) {\n"
           "            self.displayNode.isHidden = true\n"
           "        }\n")

    # 120 Hz on ProMotion iPhones unless app.json turns it off (60 Hz saves battery).
    # The workflow's "refresh_rate" input (ILVTG_REFRESH_RATE=60) overrides app.json.
    high_refresh_rate = app.get("high_refresh_rate", True) and os.environ.get("ILVTG_REFRESH_RATE", "120") != "60"
    if not high_refresh_rate:
        t.edit("refresh-rate-60hz", "Telegram/BUILD",
               "    <key>CADisableMinimumFrameDurationOnPhone</key>\n    <true/>\n",
               "    <key>CADisableMinimumFrameDurationOnPhone</key>\n    <false/>\n")


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
    settings_row(t)
    profile(t)
    location_emulation(t)
    appearance(t)
    fake_passcode(t)
    ayu_features(t)
    battery(t)
    extras(t)
    stories_and_locks(t, app)
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
