// ilvtg — extra items in the message context menu: the edit history of a message, reading the
// chat on demand while ghost mode is on for it, and saving a voice message as an M4A file.
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
import ConvertOpusToAAC

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

    if let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile, file.isVoice {
        items.append(.action(ContextMenuActionItem(text: strings.t("Сохранить как M4A", "Save as M4A"), icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Download"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            ilvExportVoiceMessage(context: context, message: message, file: file, controllerInteraction: controllerInteraction)
        })))
    }

    return items
}

/// Downloads the voice message if needed, converts it from Opus to AAC and opens the share sheet
/// with an .m4a file.
private func ilvExportVoiceMessage(context: AccountContext, message: EngineRawMessage, file: TelegramMediaFile, controllerInteraction: ChatControllerInteraction) {
    let strings = IlvStrings()
    let fetch = messageMediaFileInteractiveFetched(context: context, message: message, file: file, userInitiated: true)
    let signal: Signal<String?, NoError> = context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id))
    |> filter { $0.isComplete }
    |> take(1)
    |> mapToSignal { data -> Signal<String?, NoError> in
        return convertOpusToAAC(sourcePath: data.path, allocateTempFile: {
            return EngineTempBox.shared.tempFile(fileName: "audio.m4a").path
        })
    }
    let fetchDisposable = fetch.start()
    let _ = (signal
    |> timeout(60.0, queue: Queue.mainQueue(), alternate: .single(nil))
    |> deliverOnMainQueue).startStandalone(next: { path in
        fetchDisposable.dispose()
        guard let path = path else {
            controllerInteraction.displayUndo(.info(title: nil, text: strings.t("Не удалось сохранить голосовое", "Couldn't save the voice message"), timeout: nil, customUndoText: nil))
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = strings.t("Голосовое", "Voice") + " " + formatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.timestamp))) + ".m4a"
        let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)) != nil else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
        let activityController = UIActivityViewController(activityItems: [target], applicationActivities: nil)
        activityController.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: target)
        }
        context.sharedContext.applicationBindings.presentNativeController(activityController)
    })
}
