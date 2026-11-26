// ilvtg — ghost button in the chat header, next to the avatar.
// Copied into submodules/TelegramUI/Sources/Ilv/ by ci/prepare.py and returned from
// secondaryRightNavigationButtonForChatInterfaceState (edit "chat-ghost-button").
//
// Tapping it flips ghost mode for this chat only (read receipts, typing, story views of this
// peer); the global switches on the ilvtg tab stay as they are.

import Foundation
import UIKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatPresentationInterfaceState
import ChatNavigationButton
import SettingsUI
import UndoUI

final class IlvGhostButtonTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func pressed() {
        self.action()
    }
}

/// UIBarButtonItem keeps its target weakly; the item owns it here.
final class IlvGhostBarButtonItem: UIBarButtonItem {
    var ilvTarget: IlvGhostButtonTarget?
    var ilvGhostEnabled: Bool = false
    weak var ilvTheme: PresentationTheme?
}

func ilvGhostNavigationButton(context: AccountContext, presentationInterfaceState: ChatPresentationInterfaceState, currentButton: ChatNavigationButton?, target: Any?) -> ChatNavigationButton? {
    if !IlvPrivacy.isEnabled(.showChatGhostButton) {
        return nil
    }
    if presentationInterfaceState.interfaceState.selectionState != nil {
        return nil
    }
    guard case .standard(.default) = presentationInterfaceState.mode else {
        return nil
    }
    guard case let .peer(peerId) = presentationInterfaceState.chatLocation, peerId != context.account.peerId else {
        return nil
    }
    if presentationInterfaceState.subject != nil {
        return nil
    }

    let enabled = IlvGhost.isEnabled(for: peerId)
    let theme = presentationInterfaceState.theme
    if let currentButton = currentButton, let item = currentButton.buttonItem as? IlvGhostBarButtonItem, item.ilvGhostEnabled == enabled, item.ilvTheme === theme {
        return currentButton
    }

    let color = enabled ? theme.rootController.navigationBar.accentTextColor : theme.chat.inputPanel.panelControlColor
    let image = ilvGhostImage(color: color, size: 26.0, crossed: !enabled)

    let item = IlvGhostBarButtonItem(image: image, style: .plain, target: nil, action: nil)
    let strings = IlvStrings()
    item.accessibilityLabel = strings.chatGhost(enabled)
    item.ilvGhostEnabled = enabled
    item.ilvTheme = theme

    weak var controller = target as? ChatControllerImpl
    let ghostTarget = IlvGhostButtonTarget(action: {
        guard let controller = controller else {
            return
        }
        let updated = IlvGhost.toggle(peerId)
        controller.updateRightNavigationButtons(presentationInterfaceState: controller.presentationInterfaceState, transition: .immediate)
        let presentationData = controller.context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: strings.chatGhost(updated), timeout: 2.0, customUndoText: nil), elevatedLayout: false, action: { _ in
            return false
        }), in: .current)
    })
    item.ilvTarget = ghostTarget
    item.target = ghostTarget
    item.action = #selector(IlvGhostButtonTarget.pressed)

    return ChatNavigationButton(action: .spacer, buttonItem: item)
}
