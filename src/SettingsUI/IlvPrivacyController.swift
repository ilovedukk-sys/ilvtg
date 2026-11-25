// ilvtg — "ilvtg privacy" screen (Settings → Privacy and Security → first row).
// Copied into submodules/SettingsUI/Sources/Ilv/ by ci/prepare.py.

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

private struct IlvStrings {
    let ru: Bool

    init() {
        self.ru = (Locale.preferredLanguages.first ?? "").hasPrefix("ru")
    }

    func t(_ ru: String, _ en: String) -> String {
        return self.ru ? ru : en
    }

    var title: String { return t("Приватность ilvtg", "ilvtg Privacy") }
    var ghostHeader: String { return t("РЕЖИМ ПРИЗРАКА", "GHOST MODE") }
    var ghostFooter: String {
        return t(
            "Работает только в этом приложении. Если вы отправите сообщение в чат, сервер Telegram всё равно отметит его прочитанным. После выключения следующее прочтение подтвердит и все предыдущие сообщения. Telegram считает такие функции нарушением правил API — используйте на свой риск.",
            "Only affects this app. Sending a message to a chat still marks it as read on Telegram's side. After you turn an option off, the next read also acknowledges earlier messages. Telegram considers these features a violation of its API terms — use at your own risk."
        )
    }
    var networkHeader: String { return t("СЕТЬ", "NETWORK") }
    var networkFooter: String {
        return t(
            "Журналы событий приложения и отладочные логи звонков не отправляются в Telegram никогда. Синхронизация контактов, CallKit и подсказки Siri/Spotlight по умолчанию выключены.",
            "App event logs and call debug logs are never sent to Telegram. Contact sync, CallKit and Siri/Spotlight suggestions are off by default."
        )
    }

    func label(_ option: IlvPrivacyOption) -> String {
        switch option {
        case .hideReadReceipts:
            return t("Не отправлять «прочитано»", "Don't send read receipts")
        case .hideStoryViews:
            return t("Смотреть истории незаметно", "View stories anonymously")
        case .hideOnlineStatus:
            return t("Не показывать «в сети»", "Don't show \"online\"")
        case .hideTyping:
            return t("Не показывать «печатает…»", "Don't send \"typing…\"")
        case .blockSponsored:
            return t("Блокировать рекламу в каналах", "Block sponsored messages")
        }
    }
}

private final class IlvPrivacyControllerArguments {
    let toggle: (IlvPrivacyOption, Bool) -> Void

    init(toggle: @escaping (IlvPrivacyOption, Bool) -> Void) {
        self.toggle = toggle
    }
}

private enum IlvPrivacySection: Int32 {
    case ghost
    case network
}

private enum IlvPrivacyEntry: ItemListNodeEntry {
    case header(Int32, IlvPrivacySection, String)
    case toggle(Int32, IlvPrivacySection, IlvPrivacyOption, String, Bool)
    case footer(Int32, IlvPrivacySection, String)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, section, _):
            return section.rawValue
        case let .toggle(_, section, _, _, _):
            return section.rawValue
        case let .footer(_, section, _):
            return section.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(id, _, _):
            return id
        case let .toggle(id, _, _, _, _):
            return id
        case let .footer(id, _, _):
            return id
        }
    }

    static func ==(lhs: IlvPrivacyEntry, rhs: IlvPrivacyEntry) -> Bool {
        switch lhs {
        case let .header(lhsId, lhsSection, lhsText):
            if case let .header(rhsId, rhsSection, rhsText) = rhs, lhsId == rhsId, lhsSection == rhsSection, lhsText == rhsText {
                return true
            } else {
                return false
            }
        case let .toggle(lhsId, lhsSection, lhsOption, lhsText, lhsValue):
            if case let .toggle(rhsId, rhsSection, rhsOption, rhsText, rhsValue) = rhs, lhsId == rhsId, lhsSection == rhsSection, lhsOption == rhsOption, lhsText == rhsText, lhsValue == rhsValue {
                return true
            } else {
                return false
            }
        case let .footer(lhsId, lhsSection, lhsText):
            if case let .footer(rhsId, rhsSection, rhsText) = rhs, lhsId == rhsId, lhsSection == rhsSection, lhsText == rhsText {
                return true
            } else {
                return false
            }
        }
    }

    static func <(lhs: IlvPrivacyEntry, rhs: IlvPrivacyEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IlvPrivacyControllerArguments
        switch self {
        case let .header(_, _, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .toggle(_, _, option, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.toggle(option, updatedValue)
            })
        case let .footer(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct IlvPrivacyState: Equatable {
    var values: [IlvPrivacyOption: Bool]

    static func current() -> IlvPrivacyState {
        var values: [IlvPrivacyOption: Bool] = [:]
        for option in IlvPrivacyOption.allCases {
            values[option] = IlvPrivacy.isEnabled(option)
        }
        return IlvPrivacyState(values: values)
    }

    func value(_ option: IlvPrivacyOption) -> Bool {
        return self.values[option] ?? option.defaultValue
    }
}

private func ilvPrivacyEntries(state: IlvPrivacyState) -> [IlvPrivacyEntry] {
    let strings = IlvStrings()
    var entries: [IlvPrivacyEntry] = []

    entries.append(.header(0, .ghost, strings.ghostHeader))
    var id: Int32 = 1
    for option in [IlvPrivacyOption.hideReadReceipts, .hideStoryViews, .hideOnlineStatus, .hideTyping] {
        entries.append(.toggle(id, .ghost, option, strings.label(option), state.value(option)))
        id += 1
    }
    entries.append(.footer(50, .ghost, strings.ghostFooter))

    entries.append(.header(100, .network, strings.networkHeader))
    entries.append(.toggle(101, .network, .blockSponsored, strings.label(.blockSponsored), state.value(.blockSponsored)))
    entries.append(.footer(150, .network, strings.networkFooter))

    return entries
}

public func ilvPrivacyController(context: AccountContext) -> ViewController {
    let statePromise = ValuePromise(IlvPrivacyState.current(), ignoreRepeated: true)

    let arguments = IlvPrivacyControllerArguments(toggle: { option, value in
        IlvPrivacy.setEnabled(option, value)
        statePromise.set(IlvPrivacyState.current())
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(IlvStrings().title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: ilvPrivacyEntries(state: state), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}
