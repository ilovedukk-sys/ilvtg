// ilvtg — extra items in the message context menu: the edit history of a message and, while
// ghost mode is on for the chat, reading the chat on demand.
// Copied into submodules/TelegramUI/Sources/Ilv/ by ci/prepare.py and added to the menu by the
// edit "message-context-actions".

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import PresentationDataUtils
import UndoUI
import AppBundle
import ChatControllerInteraction
import SettingsUI

private func ilvEditHistoryText(message: EngineRawMessage, versions: [IlvEditVersion], strings: IlvStrings) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    var parts: [String] = []
    for version in versions {
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(version.date)))
        parts.append("\(date)\n\(version.text)")
    }
    parts.append(strings.t("Сейчас", "Now") + "\n" + message.text)
    return parts.joined(separator: "\n\n")
}

func ilvMessageContextActions(context: AccountContext, message: EngineRawMessage, controllerInteraction: ChatControllerInteraction) -> [ContextMenuItem] {
    let strings = IlvStrings()
    var items: [ContextMenuItem] = []

    let versions = IlvEditHistory.versions(message.id)
    if !versions.isEmpty {
        items.append(.action(ContextMenuActionItem(text: strings.t("История изменений", "Edit history"), icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let text = ilvEditHistoryText(message: message, versions: versions, strings: strings)
            controllerInteraction.presentController(textAlertController(context: context, title: strings.t("История изменений", "Edit history"), text: text, actions: [
                TextAlertAction(type: .genericAction, title: strings.t("Копировать", "Copy"), action: {
                    UIPasteboard.general.string = text
                }),
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
            ]), nil)
        })))
    }

    if message.flags.contains(.Incoming), message.id.namespace == Namespaces.Message.Cloud, IlvGhost.isEnabled(for: message.id.peerId) {
        items.append(.action(ContextMenuActionItem(text: strings.t("Отметить чат прочитанным", "Mark chat as read"), icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let _ = (ilvMarkChatReadOnServer(account: context.account, peerId: message.id.peerId)
            |> deliverOnMainQueue).startStandalone(next: { success in
                let text = success ? strings.t("Собеседник увидит, что вы прочитали чат", "The chat is marked as read for the sender") : strings.t("Не удалось отметить чат прочитанным", "Couldn't mark the chat as read")
                controllerInteraction.displayUndo(.info(title: nil, text: text, timeout: nil, customUndoText: nil))
            })
        })))
    }

    return items
}
