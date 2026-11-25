// ilvtg — privacy layer for TelegramCore.
// Copied into submodules/TelegramCore/Sources/Ilv/ by ci/prepare.py.
//
// Every MTProto request goes through Network.request / requestWithAdditionalInfo. ci/prepare.py
// adds a call to ilvShouldBlockRequest() at the start of both, so a blocked method never leaves
// the device: the caller receives an RPC error, which every call site listed below already
// swallows (they catch the error and complete without retrying).

import Foundation

public enum IlvPrivacyOption: String, CaseIterable {
    /// messages.readHistory and friends: the sender never sees the double check.
    case hideReadReceipts
    /// stories.readStories / incrementStoryViews: you are not listed among story viewers.
    case hideStoryViews
    /// account.updateStatus: your "online" / "last seen" is not refreshed by this app.
    case hideOnlineStatus
    /// messages.setTyping: no "typing…", "recording…", "uploading…" indicators.
    case hideTyping
    /// Sponsored messages in channels and the proxy promo channel are never requested.
    case blockSponsored

    public var defaultValue: Bool {
        switch self {
        case .blockSponsored:
            return true
        case .hideReadReceipts, .hideStoryViews, .hideOnlineStatus, .hideTyping:
            return false
        }
    }

    var defaultsKey: String {
        return "ilvtg.privacy." + self.rawValue
    }

    /// Normalized TL method names (see ilvNormalizeMethodName).
    var blockedMethods: Set<String> {
        switch self {
        case .hideReadReceipts:
            return [
                "messagesreadhistory",
                "channelsreadhistory",
                "messagesreaddiscussion",
                "messagesreadmessagecontents",
                "channelsreadmessagecontents",
                "messagesreadencryptedhistory"
            ]
        case .hideStoryViews:
            return [
                "storiesreadstories",
                "storiesincrementstoryviews"
            ]
        case .hideOnlineStatus:
            return [
                "accountupdatestatus"
            ]
        case .hideTyping:
            return [
                "messagessettyping",
                "messagessetencryptedtyping"
            ]
        case .blockSponsored:
            return [
                "messagesgetsponsoredmessages",
                "messagesviewsponsoredmessage",
                "messagesclicksponsoredmessage",
                "helpgetpromodata"
            ]
        }
    }
}

public enum IlvPrivacy {
    public static func isEnabled(_ option: IlvPrivacyOption) -> Bool {
        if let value = UserDefaults.standard.object(forKey: option.defaultsKey) as? Bool {
            return value
        }
        return option.defaultValue
    }

    public static func setEnabled(_ option: IlvPrivacyOption, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: option.defaultsKey)
    }
}

/// Telemetry that is never sent, regardless of settings: app event logs and call debug logs.
private let ilvAlwaysBlockedMethods: Set<String> = [
    "helpsaveapplog",
    "phonesavecalldebug",
    "phonesavecalllog"
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
    for option in IlvPrivacyOption.allCases {
        if option.blockedMethods.contains(method) && IlvPrivacy.isEnabled(option) {
            return true
        }
    }
    return false
}
