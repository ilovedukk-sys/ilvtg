// ilvtg — profile additions: the "ilvtg" settings row icon, the "ID" row and streamer mode.
// Copied into submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/ by ci/prepare.py.

import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore
import TelegramPresentationData
import UndoUI
import SettingsUI

/// Icon of the "ilvtg" row in the main Settings list (edit "settings-row").
let ilvSettingsRowIcon: UIImage = ilvSettingsIcon

/// Streamer mode: personal values in profiles are shown as dots until tapped. Revealed values stay
/// visible until the app restarts or streamer mode is switched off and on.
enum IlvStreamer {
    private static var revealed = Set<String>()
    private static var revealedWhileActive = false

    static var isActive: Bool {
        let active = IlvPrivacy.isEnabled(.streamerMode)
        if !active && revealedWhileActive {
            revealed.removeAll()
            revealedWhileActive = false
        }
        return active
    }

    static func isHidden(_ value: String) -> Bool {
        return isActive && !revealed.contains(value)
    }

    /// The value, or dots while it is hidden.
    static func text(_ value: String) -> String {
        if isHidden(value) {
            return String(repeating: "•", count: max(6, min(12, value.count)))
        }
        return value
    }

    static func optionalText(_ value: String?) -> String? {
        guard let value = value else {
            return nil
        }
        return text(value)
    }

    /// Reveals a hidden value. Returns true if the tap was used for that, so the caller skips its
    /// normal action.
    static func reveal(_ value: String, interaction: PeerInfoInteraction) -> Bool {
        if !isHidden(value) {
            return false
        }
        revealed.insert(value)
        revealedWhileActive = true
        interaction.requestLayout(true)
        return true
    }
}

/// Bot API style id: users as is, basic groups negative, channels and supergroups -100….
private func ilvPeerIdString(_ peer: EnginePeer) -> String {
    let value = peer.id.id._internalGetInt64Value()
    switch peer {
    case .user, .secretChat:
        return "\(value)"
    case .legacyGroup:
        return "-\(value)"
    case .channel:
        return "-100\(value)"
    case .community:
        return "\(value)"
    }
}

/// The "ID" row at the end of the profile's main section.
func ilvPeerIdItem(data: PeerInfoScreenData, presentationData: PresentationData, interaction: PeerInfoInteraction) -> PeerInfoScreenItem? {
    guard IlvPrivacy.isEnabled(.showPeerId), let peer = data.peer else {
        return nil
    }
    let idText = ilvPeerIdString(peer)
    let copiedText = (Locale.preferredLanguages.first ?? "").hasPrefix("ru") ? "ID скопирован" : "ID copied"
    return PeerInfoScreenLabeledValueItem(id: 99_000, label: "ID", text: IlvStreamer.text(idText), textColor: .primary, action: { _, _ in
        if IlvStreamer.reveal(idText, interaction: interaction) {
            return
        }
        UIPasteboard.general.string = idText
        interaction.getController()?.present(UndoOverlayController(presentationData: presentationData, content: .copy(text: copiedText), elevatedLayout: false, action: { _ in
            return false
        }), in: .current)
    }, requestLayout: { animated in
        interaction.requestLayout(animated)
    })
}
