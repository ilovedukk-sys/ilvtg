// ilvtg — locked chats: opening one asks for Face ID / Touch ID / the device passcode, and its
// long-press preview stays empty. An unlocked chat stays open for five minutes.
// Copied into submodules/TelegramUI/Sources/Ilv/ by ci/prepare.py (edits "chat-lock-*").

import Foundation
import LocalAuthentication
import SwiftSignalKit
import TelegramCore

private var ilvUnlockedChats: [EnginePeer.Id: Double] = [:]
private let ilvUnlockDuration: Double = 5.0 * 60.0

func ilvChatNeedsUnlock(_ peerId: EnginePeer.Id) -> Bool {
    guard IlvChatLock.isLocked(peerId) else {
        return false
    }
    if let unlockedAt = ilvUnlockedChats[peerId], CFAbsoluteTimeGetCurrent() - unlockedAt < ilvUnlockDuration {
        return false
    }
    return true
}

func ilvUnlockChat(_ peerId: EnginePeer.Id, completion: @escaping () -> Void) {
    let authContext = LAContext()
    var error: NSError?
    guard authContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        // Without a device passcode there is nothing to check against.
        ilvUnlockedChats[peerId] = CFAbsoluteTimeGetCurrent()
        completion()
        return
    }
    let reason = (Locale.preferredLanguages.first ?? "").hasPrefix("ru") ? "Открыть защищённый чат" : "Open a locked chat"
    authContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason, reply: { success, _ in
        Queue.mainQueue().async {
            if success {
                ilvUnlockedChats[peerId] = CFAbsoluteTimeGetCurrent()
                completion()
            }
        }
    })
}
