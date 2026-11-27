// ilvtg — confirmation before starting a call, so a stray tap on the call button does not ring
// anyone. Copied into submodules/TelegramUI/Sources/Ilv/ by ci/prepare.py; AccountContextImpl's
// requestCall asks first (edit "confirm-calls").

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import PresentationDataUtils

func ilvConfirmCall(context: AccountContext, peerId: EnginePeer.Id, isVideo: Bool, confirmed: @escaping () -> Void) {
    let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
    |> deliverOnMainQueue).start(next: { peer in
        let ru = (Locale.preferredLanguages.first ?? "").hasPrefix("ru")
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let name = peer?.compactDisplayTitle ?? ""
        let title: String
        if isVideo {
            title = ru ? "Видеозвонок" : "Video call"
        } else {
            title = ru ? "Аудиозвонок" : "Voice call"
        }
        let text = ru ? "Позвонить \(name)?" : "Call \(name)?"
        let alert = textAlertController(context: context, title: title, text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: ru ? "Позвонить" : "Call", action: {
                confirmed()
            })
        ])
        context.sharedContext.mainWindow?.present(alert, on: .root)
    })
}
