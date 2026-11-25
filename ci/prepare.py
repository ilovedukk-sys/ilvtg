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
    def __init__(self, source: Path):
        self.source = source
        self.applied = []

    def edit(self, name: str, relpath: str, old: str, new: str, count: int = 1):
        path = self.source / relpath
        text = read_exact(path)
        found = text.count(old)
        if found != count:
            raise SystemExit(f"[ilvtg] edit '{name}': expected {count} match(es) in {relpath}, found {found}")
        write_exact(path, text.replace(old, new))
        self.applied.append(name)

    def copy(self, name: str, src: Path, relpath: str):
        dst = self.source / relpath
        if dst.exists():
            raise SystemExit(f"[ilvtg] copy '{name}': {relpath} already exists")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        self.applied.append(name)

    def append(self, name: str, relpath: str, text: str):
        path = self.source / relpath
        current = read_exact(path)
        if not current.endswith("\n"):
            current += "\n"
        write_exact(path, current + text)
        self.applied.append(name)


def privacy_layer(t: Tree):
    t.copy("privacy-core", ROOT / "src/TelegramCore/IlvPrivacy.swift",
           "submodules/TelegramCore/Sources/Ilv/IlvPrivacy.swift")

    # Single choke point: both request entry points of Network refuse blocked methods.
    t.edit("network-guard", "submodules/TelegramCore/Sources/Network/Network.swift",
           "        return Signal { [requestService] subscriber in\n"
           "            let request = NetworkEngineRequest(\n",
           "        return Signal { [requestService] subscriber in\n"
           "            if ilvShouldBlockRequest(data.0.name) {\n"
           "                subscriber.putError(MTRpcError(errorCode: 400, errorDescription: \"ILVTG_PRIVACY_BLOCKED\"))\n"
           "                return EmptyDisposable\n"
           "            }\n"
           "            let request = NetworkEngineRequest(\n",
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
    parser.add_argument("--no-git-check", action="store_true", help="for local dry runs on an unpacked archive")
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

    t = Tree(source)
    privacy_layer(t)
    privacy_defaults(t)
    settings_screen(t)
    branding(t, app)
    build_tweaks(t, app)

    marker.write_text(pin["commit"] + "\n", encoding="utf-8")
    print(f"[ilvtg] applied {len(t.applied)} changes to {pin['commit']}:")
    for name in t.applied:
        print("  - " + name)


if __name__ == "__main__":
    main()
