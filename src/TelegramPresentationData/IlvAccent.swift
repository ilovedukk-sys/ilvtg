// ilvtg — cherry accent color for the built-in themes.
// Copied into submodules/TelegramPresentationData/Sources/ by ci/prepare.py and applied in
// makePresentationTheme (edit "cherry-accent").

import Foundation
import UIKit
import Display
import TelegramCore
import TelegramUIPreferences

private let ilvDefaultBlueAccents: Set<UInt32> = [0x0088ff, 0x3e88f7, 0x007aff, 0x007ee5]

/// The accent color for a built-in theme: cherry when none was chosen or the default blue is in
/// use, the user's own choice otherwise.
func ilvAccentColor(_ accentColor: UIColor?, reference: PresentationBuiltinThemeReference) -> UIColor? {
    if !IlvPrivacy.isEnabled(.cherryAccent) {
        return accentColor
    }
    if let accentColor = accentColor, !ilvDefaultBlueAccents.contains(accentColor.rgb) {
        return accentColor
    }
    switch reference {
    case .night, .nightAccent:
        return UIColor(rgb: 0xe0446a)
    case .day, .dayClassic:
        return UIColor(rgb: 0xb3133d)
    }
}
