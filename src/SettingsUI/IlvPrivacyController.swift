// ilvtg — settings screen. Settings → "ilvtg" (own row in the main list) and Settings → Privacy
// and Security → first row.
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
import OverlayStatusController
import UndoUI
import TelegramUIPreferences

public struct IlvStrings {
    public let ru: Bool

    public init() {
        self.ru = (Locale.preferredLanguages.first ?? "").hasPrefix("ru")
    }

    public func t(_ ru: String, _ en: String) -> String {
        return self.ru ? ru : en
    }

    var title: String { return "ilvtg" }
    var ghostHeader: String { return t("РЕЖИМ ПРИЗРАКА", "GHOST MODE") }
    var ghostMaster: String { return t("Режим призрака", "Ghost mode") }
    var ghostFooter: String {
        return t(
            "Кнопка с призраком в шапке чата включает и выключает режим отдельно для этого чата: «прочитано», «печатает…» и просмотры историй этого собеседника. Если вы отправите сообщение, сервер всё равно отметит чат прочитанным. Telegram считает такие функции нарушением правил API — используйте на свой риск.",
            "The ghost button in the chat header turns ghost mode on or off for that chat only: read receipts, typing and story views for that peer. Sending a message still marks the chat as read on Telegram's side. Telegram considers these features a violation of its API terms — use at your own risk."
        )
    }
    func resetChats(_ count: Int) -> String {
        return t("Сбросить настройки чатов (\(count))", "Reset per-chat settings (\(count))")
    }
    var messagesHeader: String { return t("СООБЩЕНИЯ", "MESSAGES") }
    var messagesFooter: String {
        return t(
            "Удалённые собеседником сообщения остаются в чате с пометкой «удалено». Самоуничтожающиеся сообщения не исчезают по таймеру, а одноразовые фото, видео, голосовые и кружки можно открывать сколько угодно раз: отправитель не узнает, что вы их открыли. Работает для сообщений, полученных, пока опция включена.",
            "Messages deleted by the other side stay in the chat marked \"deleted\". Self-destructing messages are not removed by their timer, and view-once photos, videos, voice and video messages can be opened any number of times without the sender being notified. Applies to messages received while the option is on."
        )
    }
    func clearDeletedMarks(_ count: Int) -> String {
        return t("Снять отметки «удалено» (\(count))", "Clear \"deleted\" marks (\(count))")
    }
    var mediaHeader: String { return t("ГОЛОСОВЫЕ И КРУЖКИ", "VOICE AND VIDEO MESSAGES") }
    var voiceHeader: String { return t("ИЗМЕНЕНИЕ ГОЛОСА", "VOICE CHANGER") }
    var mediaFooter: String {
        return t(
            "Голос меняется при записи голосовых сообщений и кружков. Лица в кружках замазываются перед отправкой, обработка занимает несколько секунд; пока включена хотя бы одна из этих функций, кружок загружается только после окончания записи.",
            "The voice is changed while recording voice and video messages. Faces in video messages are pixelated before sending, which takes a few seconds; while either feature is on, a video message is uploaded only after recording ends."
        )
    }
    var toolsHeader: String { return t("ИНСТРУМЕНТЫ", "TOOLS") }
    var exportChat: String { return t("Экспорт чата…", "Export chat…") }
    var exportFooter: String {
        return t(
            "Вся история выбранного чата сохраняется в текстовый файл (без вложений), его можно сохранить в «Файлы» или отправить.",
            "The whole history of the chosen chat is saved to a text file (without attachments) that you can save to Files or share."
        )
    }
    var exportTitle: String { return t("Экспорт чата", "Export chat") }
    var exportFailed: String { return t("Не удалось выгрузить историю чата.", "Couldn't download the chat history.") }
    var networkHeader: String { return t("СЕТЬ", "NETWORK") }
    var networkFooter: String {
        return t(
            "Журналы событий приложения и отладочные логи звонков не отправляются в Telegram никогда. Синхронизация контактов, CallKit и подсказки Siri/Spotlight по умолчанию выключены.",
            "App event logs and call debug logs are never sent to Telegram. Contact sync, CallKit and Siri/Spotlight suggestions are off by default."
        )
    }

    var ghostSendingFooter: String {
        return t(
            "«Отправлять, не выходя в сеть» работает вместе с «Не показывать «в сети»»: сообщение уходит как отложенное на 12 секунд, и сервер публикует его сам, не отмечая вас в сети. До публикации оно лежит в «Отложенных сообщениях» чата.",
            "\"Send without going online\" works together with \"Don't show online\": a message is sent as scheduled 12 seconds ahead and the server publishes it itself without marking you online. Until then it is in the chat's scheduled messages."
        )
    }
    var contentHeader: String { return t("ЗАЩИЩЁННЫЙ КОНТЕНТ", "PROTECTED CONTENT") }
    var contentFooter: String {
        return t(
            "В чатах и каналах с запретом копирования можно копировать текст, сохранять медиа и делать скриншоты. Пересылка оттуда тоже работает: сообщения отправляются от вас как новые, фото, видео, голосовые и файлы скачиваются и загружаются заново. О скриншотах секретных чатов и одноразовых медиа собеседник не узнает.",
            "In chats and channels that restrict saving content you can copy text, save media and take screenshots. Forwarding works too: messages are sent from you as new ones, and photos, videos, voice messages and files are downloaded and uploaded again. Screenshots of secret chats and view-once media are not reported."
        )
    }
    var editHistoryFooter: String {
        return t(
            "Если собеседник изменит сообщение, прежний текст сохранится: долгое нажатие на сообщение → «История изменений». В режиме призрака там же есть «Отметить чат прочитанным».",
            "When someone edits a message, the earlier text is kept: long-press the message → \"Edit history\". In ghost mode the same menu has \"Mark chat as read\"."
        )
    }
    func clearEditHistory(_ count: Int) -> String {
        return t("Очистить историю изменений (\(count))", "Clear edit history (\(count))")
    }
    var appearanceHeader: String { return t("ОФОРМЛЕНИЕ", "APPEARANCE") }
    var appearanceFooter: String {
        return t(
            "Вишнёвый цвет заменяет стандартный синий во встроенных темах; изменение применяется после перезапуска приложения. Прозрачность применяется к пузырям сообщений после повторного открытия чата.",
            "Cherry replaces the default blue in the built-in themes; takes effect after restarting the app. Transparency applies to message bubbles after reopening a chat."
        )
    }
    var bubbleAlphaHeader: String { return t("ПРОЗРАЧНОСТЬ СООБЩЕНИЙ", "MESSAGE TRANSPARENCY") }
    func bubbleAlpha(_ value: Double) -> String {
        if value >= 0.999 {
            return t("Без прозрачности", "Opaque")
        }
        return t("Непрозрачность \(Int((value * 100.0).rounded()))%", "Opacity \(Int((value * 100.0).rounded()))%")
    }
    var streamerFooter: String {
        return t(
            "Режим стримера скрывает номера телефонов, юзернеймы и ID в профилях — нажмите на скрытое значение, чтобы показать его. Номер и юзернейм в шапке настроек скрыты, пока режим включён.",
            "Streamer mode hides phone numbers, usernames and IDs in profiles — tap a hidden value to reveal it. The number and username at the top of Settings stay hidden while the mode is on."
        )
    }
    var tabsHeader: String { return t("ПАНЕЛЬ ВКЛАДОК", "TAB BAR") }
    var showContactsTab: String { return t("Вкладка «Контакты»", "Contacts tab") }
    var showCallsTab: String { return t("Вкладка «Звонки»", "Calls tab") }
    var showTabTitles: String { return t("Подписи вкладок", "Tab titles") }
    var locationHeader: String { return t("ЭМУЛЯЦИЯ ГЕОПОЗИЦИИ", "LOCATION EMULATION") }
    func locationOn(_ latitude: Double, _ longitude: Double) -> String {
        return t("Включена: ", "On: ") + String(format: "%.5f, %.5f", latitude, longitude)
    }
    var locationOff: String { return t("Выключена", "Off") }
    var locationDisable: String { return t("Выключить эмуляцию", "Turn off emulation") }
    var locationFooter: String {
        return t(
            "Чтобы включить: откройте в любом чате вложения → «Геопозиция», передвиньте карту так, чтобы метка стояла в нужном месте, и нажмите «Эмулировать геопозицию здесь». Приложение будет сообщать эту точку вместо настоящей — при отправке текущей и трансляции геопозиции.",
            "To turn on: in any chat open attachments → Location, move the map so the pin is where you want and tap \"Emulate location here\". The app then reports that point instead of your real location — when sending your current or live location."
        )
    }
    var duressHeader: String { return t("ФЕЙК-ПАРОЛЬ", "FAKE PASSCODE") }
    var duressSet: String { return t("Задать фейк-пароль…", "Set fake passcode…") }
    var duressChange: String { return t("Изменить фейк-пароль…", "Change fake passcode…") }
    var duressClear: String { return t("Удалить фейк-пароль", "Remove fake passcode") }
    var duressLogout: String { return t("Выйти из аккаунтов и стереть данные", "Log out and erase data") }
    var duressDelete: String { return t("Удалить аккаунты навсегда", "Delete accounts permanently") }
    var duressFooter: String {
        return t(
            "Работает, если включён код-пароль приложения (Конфиденциальность → Код-пароль). Если на экране блокировки ввести фейк-пароль вместо настоящего, приложение откроется уже без аккаунтов: все аккаунты будут завершены на сервере, а данные на устройстве стёрты. В режиме «Удалить навсегда» аккаунты Telegram удаляются безвозвратно вместе со всеми чатами и контактами — восстановить их будет невозможно (для аккаунтов с облачным паролем Telegram может отложить удаление). Фейк-пароль должен отличаться от настоящего.",
            "Works when the app passcode is on (Privacy → Passcode). Entering the fake passcode on the lock screen instead of the real one opens the app with no accounts: every account is logged out on the server and local data is erased. With \"Delete permanently\" the Telegram accounts are deleted for good with all chats and contacts — they cannot be restored (Telegram may delay deletion for accounts with a cloud password). The fake passcode must differ from the real one."
        )
    }
    var duressPromptTitle: String { return t("Фейк-пароль", "Fake passcode") }
    var duressPromptText: String { return t("Введите фейк-пароль дважды. Он должен отличаться от настоящего код-пароля.", "Enter the fake passcode twice. It must differ from your real passcode.") }
    var duressMismatch: String { return t("Пароли не совпадают.", "The passcodes don't match.") }
    var duressSaved: String { return t("Фейк-пароль сохранён.", "Fake passcode saved.") }
    var save: String { return t("Сохранить", "Save") }
    var cancel: String { return t("Отмена", "Cancel") }

    public func label(_ option: IlvPrivacyOption) -> String {
        switch option {
        case .hideReadReceipts:
            return t("Не отправлять «прочитано»", "Don't send read receipts")
        case .hideStoryViews:
            return t("Смотреть истории незаметно", "View stories anonymously")
        case .hideOnlineStatus:
            return t("Не показывать «в сети»", "Don't show \"online\"")
        case .hideTyping:
            return t("Не показывать «печатает…»", "Don't send \"typing…\"")
        case .showChatGhostButton:
            return t("Кнопка призрака в чатах", "Ghost button in chats")
        case .blockSponsored:
            return t("Блокировать рекламу в каналах", "Block sponsored messages")
        case .keepDeletedMessages:
            return t("Сохранять удалённые сообщения", "Keep deleted messages")
        case .keepSelfDestructing:
            return t("Сохранять самоуничтожающиеся", "Keep self-destructing messages")
        case .replayViewOnce:
            return t("Одноразовые — без ограничений", "Unlimited view-once replays")
        case .blurFacesInVideoMessages:
            return t("Замазывать лица в кружках", "Blur faces in video messages")
        case .streamerMode:
            return t("Режим стримера", "Streamer mode")
        case .showPeerId:
            return t("Показывать ID в профиле", "Show ID in profiles")
        case .cherryAccent:
            return t("Вишнёвый цвет интерфейса", "Cherry accent color")
        case .ghostSending:
            return t("Отправлять, не выходя в сеть", "Send without going online")
        case .ignoreCopyProtection:
            return t("Обходить запрет копирования", "Ignore copy restrictions")
        case .hideScreenshots:
            return t("Не сообщать о скриншотах", "Don't report screenshots")
        case .keepEditHistory:
            return t("Сохранять историю изменений", "Keep edit history")
        }
    }

    public func label(_ preset: IlvVoicePreset) -> String {
        switch preset {
        case .off:
            return t("Без изменений", "Off")
        case .lower:
            return t("Ниже", "Lower")
        case .muchLower:
            return t("Намного ниже", "Much lower")
        case .higher:
            return t("Выше", "Higher")
        case .muchHigher:
            return t("Намного выше", "Much higher")
        }
    }

    public func chatGhost(_ enabled: Bool) -> String {
        return enabled ? t("Режим призрака включён для этого чата", "Ghost mode is on for this chat") : t("Режим призрака выключен для этого чата", "Ghost mode is off for this chat")
    }
}

/// Ghost glyph used for the tab and the chat header button.
public func ilvGhostImage(color: UIColor, size: CGFloat, crossed: Bool) -> UIImage {
    let canvas = CGSize(width: size, height: size)
    return UIGraphicsImageRenderer(size: canvas).image { rendererContext in
        let context = rendererContext.cgContext
        let width = size * 0.66
        let left = (size - width) / 2.0
        let right = left + width
        let top = size * 0.1
        let radius = width / 2.0
        let bottom = size * 0.84
        let wave = size * 0.07

        let path = UIBezierPath()
        path.move(to: CGPoint(x: left, y: top + radius))
        path.addArc(withCenter: CGPoint(x: left + radius, y: top + radius), radius: radius, startAngle: .pi, endAngle: 0.0, clockwise: true)
        path.addLine(to: CGPoint(x: right, y: bottom))
        let scallops = 3
        let step = width / CGFloat(scallops)
        for index in 0 ..< scallops {
            let fromX = right - step * CGFloat(index)
            let toX = fromX - step
            path.addQuadCurve(to: CGPoint(x: toX, y: bottom), controlPoint: CGPoint(x: (fromX + toX) / 2.0, y: bottom + (index % 2 == 0 ? wave : -wave)))
        }
        path.close()
        color.setFill()
        path.fill()

        context.setBlendMode(.clear)
        let eyeWidth = size * 0.1
        let eyeHeight = size * 0.15
        let eyeY = top + radius * 0.75
        UIBezierPath(ovalIn: CGRect(x: left + width * 0.3 - eyeWidth / 2.0, y: eyeY, width: eyeWidth, height: eyeHeight)).fill()
        UIBezierPath(ovalIn: CGRect(x: left + width * 0.7 - eyeWidth / 2.0, y: eyeY, width: eyeWidth, height: eyeHeight)).fill()

        if crossed {
            let start = CGPoint(x: size * 0.12, y: size * 0.1)
            let end = CGPoint(x: size * 0.88, y: size * 0.9)
            context.setLineCap(.round)
            context.setLineWidth(size * 0.16)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()

            context.setBlendMode(.normal)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(size * 0.07)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
    }
}

/// Icon of the "ilvtg" row in the main Settings list.
public let ilvSettingsIcon: UIImage = {
    let size = CGSize(width: 30.0, height: 30.0)
    return UIGraphicsImageRenderer(size: size).image { _ in
        let rect = CGRect(origin: .zero, size: size)
        UIColor(red: 0.69, green: 0.07, blue: 0.23, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 8.0).fill()
        let ghost = ilvGhostImage(color: .white, size: 22.0, crossed: false)
        ghost.draw(in: CGRect(x: 4.0, y: 4.0, width: 22.0, height: 22.0))
    }
}()

private final class IlvPrivacyControllerArguments {
    let toggle: (IlvPrivacyOption, Bool) -> Void
    let setGhostMode: (Bool) -> Void
    let setFlag: (IlvFlag, Bool) -> Void
    let choose: (IlvChoice) -> Void
    let perform: (IlvPrivacyAction) -> Void

    init(toggle: @escaping (IlvPrivacyOption, Bool) -> Void, setGhostMode: @escaping (Bool) -> Void, setFlag: @escaping (IlvFlag, Bool) -> Void, choose: @escaping (IlvChoice) -> Void, perform: @escaping (IlvPrivacyAction) -> Void) {
        self.toggle = toggle
        self.setGhostMode = setGhostMode
        self.setFlag = setFlag
        self.choose = choose
        self.perform = perform
    }
}

private enum IlvPrivacySection: Int32 {
    case ghost
    case messages
    case voice
    case media
    case content
    case appearance
    case bubbleAlpha
    case tabs
    case location
    case duress
    case tools
    case network
}

private enum IlvPrivacyAction: Equatable {
    case resetChats
    case clearDeletedMarks
    case exportChat
    case disableLocation
    case setDuress
    case clearDuress
    case clearEditHistory

    var isDestructive: Bool {
        switch self {
        case .resetChats, .clearDeletedMarks, .clearDuress, .clearEditHistory:
            return true
        case .exportChat, .disableLocation, .setDuress:
            return false
        }
    }
}

/// Switches that are not IlvPrivacyOption values.
private enum IlvFlag: Equatable {
    case showContactsTab
    case showCallsTab
    case showTabTitles
}

/// One-of-many rows.
private enum IlvChoice: Equatable {
    case voice(IlvVoicePreset)
    case bubbleAlpha(Double)
    case duressAction(IlvDuress.Action)
}

private enum IlvPrivacyEntry: ItemListNodeEntry {
    case header(Int32, IlvPrivacySection, String)
    case ghostMaster(Int32, String, Bool)
    case toggle(Int32, IlvPrivacySection, IlvPrivacyOption, String, Bool)
    case flag(Int32, IlvPrivacySection, IlvFlag, String, Bool)
    case choice(Int32, IlvPrivacySection, IlvChoice, String, Bool)
    case info(Int32, IlvPrivacySection, String)
    case action(Int32, IlvPrivacySection, IlvPrivacyAction, String)
    case footer(Int32, IlvPrivacySection, String)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, section, _):
            return section.rawValue
        case .ghostMaster:
            return IlvPrivacySection.ghost.rawValue
        case let .toggle(_, section, _, _, _):
            return section.rawValue
        case let .flag(_, section, _, _, _):
            return section.rawValue
        case let .choice(_, section, _, _, _):
            return section.rawValue
        case let .info(_, section, _):
            return section.rawValue
        case let .action(_, section, _, _):
            return section.rawValue
        case let .footer(_, section, _):
            return section.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(id, _, _):
            return id
        case let .ghostMaster(id, _, _):
            return id
        case let .toggle(id, _, _, _, _):
            return id
        case let .flag(id, _, _, _, _):
            return id
        case let .choice(id, _, _, _, _):
            return id
        case let .info(id, _, _):
            return id
        case let .action(id, _, _, _):
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
        case let .ghostMaster(lhsId, lhsText, lhsValue):
            if case let .ghostMaster(rhsId, rhsText, rhsValue) = rhs, lhsId == rhsId, lhsText == rhsText, lhsValue == rhsValue {
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
        case let .flag(lhsId, lhsSection, lhsFlag, lhsText, lhsValue):
            if case let .flag(rhsId, rhsSection, rhsFlag, rhsText, rhsValue) = rhs, lhsId == rhsId, lhsSection == rhsSection, lhsFlag == rhsFlag, lhsText == rhsText, lhsValue == rhsValue {
                return true
            } else {
                return false
            }
        case let .choice(lhsId, lhsSection, lhsChoice, lhsText, lhsValue):
            if case let .choice(rhsId, rhsSection, rhsChoice, rhsText, rhsValue) = rhs, lhsId == rhsId, lhsSection == rhsSection, lhsChoice == rhsChoice, lhsText == rhsText, lhsValue == rhsValue {
                return true
            } else {
                return false
            }
        case let .info(lhsId, lhsSection, lhsText):
            if case let .info(rhsId, rhsSection, rhsText) = rhs, lhsId == rhsId, lhsSection == rhsSection, lhsText == rhsText {
                return true
            } else {
                return false
            }
        case let .action(lhsId, lhsSection, lhsAction, lhsText):
            if case let .action(rhsId, rhsSection, rhsAction, rhsText) = rhs, lhsId == rhsId, lhsSection == rhsSection, lhsAction == rhsAction, lhsText == rhsText {
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
        case let .ghostMaster(_, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.setGhostMode(updatedValue)
            })
        case let .toggle(_, _, option, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.toggle(option, updatedValue)
            })
        case let .flag(_, _, flag, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.setFlag(flag, updatedValue)
            })
        case let .choice(_, _, choice, text, value):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: text, style: .left, checked: value, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.choose(choice)
            })
        case let .info(_, _, text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .action(_, _, action, text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: action.isDestructive ? .destructive : .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.perform(action)
            })
        case let .footer(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct IlvPrivacyState: Equatable {
    var values: [IlvPrivacyOption: Bool]
    var voicePreset: IlvVoicePreset
    var overriddenChats: Int
    var deletedMarks: Int
    var editHistoryCount: Int
    var bubbleAlpha: Double
    var hideContactsTab: Bool
    var hideTabTitles: Bool
    var emulatedLatitude: Double?
    var emulatedLongitude: Double?
    var duressSet: Bool
    var duressAction: IlvDuress.Action

    static func current() -> IlvPrivacyState {
        var values: [IlvPrivacyOption: Bool] = [:]
        for option in IlvPrivacyOption.allCases {
            values[option] = IlvPrivacy.isEnabled(option)
        }
        let coordinate = IlvLocationEmulation.coordinate
        return IlvPrivacyState(values: values, voicePreset: IlvVoicePreset.current, overriddenChats: IlvGhost.overriddenChatCount, deletedMarks: IlvDeletedMessages.count, editHistoryCount: IlvEditHistory.count, bubbleAlpha: IlvAppearance.bubbleAlpha, hideContactsTab: IlvTabs.hideContacts, hideTabTitles: IlvTabs.hideTitles, emulatedLatitude: coordinate?.0, emulatedLongitude: coordinate?.1, duressSet: IlvDuress.isSet, duressAction: IlvDuress.action)
    }

    func value(_ option: IlvPrivacyOption) -> Bool {
        return self.values[option] ?? option.defaultValue
    }
}

private func ilvPrivacyEntries(state: IlvPrivacyState, showCallsTab: Bool) -> [IlvPrivacyEntry] {
    let strings = IlvStrings()
    var entries: [IlvPrivacyEntry] = []

    entries.append(.header(0, .ghost, strings.ghostHeader))
    entries.append(.ghostMaster(1, strings.ghostMaster, IlvPrivacyOption.ghostOptions.allSatisfy { state.value($0) }))
    var id: Int32 = 2
    for option in IlvPrivacyOption.ghostOptions + [.ghostSending, .showChatGhostButton] {
        entries.append(.toggle(id, .ghost, option, strings.label(option), state.value(option)))
        id += 1
    }
    if state.overriddenChats > 0 {
        entries.append(.action(18, .ghost, .resetChats, strings.resetChats(state.overriddenChats)))
    }
    entries.append(.footer(19, .ghost, strings.ghostFooter + "\n\n" + strings.ghostSendingFooter))

    entries.append(.header(20, .messages, strings.messagesHeader))
    entries.append(.toggle(21, .messages, .keepDeletedMessages, strings.label(.keepDeletedMessages), state.value(.keepDeletedMessages)))
    entries.append(.toggle(22, .messages, .keepSelfDestructing, strings.label(.keepSelfDestructing), state.value(.keepSelfDestructing)))
    entries.append(.toggle(23, .messages, .replayViewOnce, strings.label(.replayViewOnce), state.value(.replayViewOnce)))
    entries.append(.toggle(24, .messages, .keepEditHistory, strings.label(.keepEditHistory), state.value(.keepEditHistory)))
    if state.deletedMarks > 0 {
        entries.append(.action(37, .messages, .clearDeletedMarks, strings.clearDeletedMarks(state.deletedMarks)))
    }
    if state.editHistoryCount > 0 {
        entries.append(.action(38, .messages, .clearEditHistory, strings.clearEditHistory(state.editHistoryCount)))
    }
    entries.append(.footer(39, .messages, strings.messagesFooter + "\n\n" + strings.editHistoryFooter))

    entries.append(.header(80, .content, strings.contentHeader))
    entries.append(.toggle(81, .content, .ignoreCopyProtection, strings.label(.ignoreCopyProtection), state.value(.ignoreCopyProtection)))
    entries.append(.toggle(82, .content, .hideScreenshots, strings.label(.hideScreenshots), state.value(.hideScreenshots)))
    entries.append(.footer(99, .content, strings.contentFooter))

    entries.append(.header(40, .voice, strings.voiceHeader))
    id = 41
    for preset in IlvVoicePreset.allCases {
        entries.append(.choice(id, .voice, .voice(preset), strings.label(preset), state.voicePreset == preset))
        id += 1
    }

    entries.append(.header(60, .media, strings.mediaHeader))
    entries.append(.toggle(61, .media, .blurFacesInVideoMessages, strings.label(.blurFacesInVideoMessages), state.value(.blurFacesInVideoMessages)))
    entries.append(.footer(79, .media, strings.mediaFooter))

    entries.append(.header(200, .appearance, strings.appearanceHeader))
    entries.append(.toggle(201, .appearance, .cherryAccent, strings.label(.cherryAccent), state.value(.cherryAccent)))
    entries.append(.toggle(202, .appearance, .streamerMode, strings.label(.streamerMode), state.value(.streamerMode)))
    entries.append(.toggle(203, .appearance, .showPeerId, strings.label(.showPeerId), state.value(.showPeerId)))
    entries.append(.footer(219, .appearance, strings.appearanceFooter + "\n\n" + strings.streamerFooter))

    entries.append(.header(220, .bubbleAlpha, strings.bubbleAlphaHeader))
    id = 221
    for value in IlvAppearance.bubbleAlphaPresets {
        entries.append(.choice(id, .bubbleAlpha, .bubbleAlpha(value), strings.bubbleAlpha(value), abs(state.bubbleAlpha - value) < 0.001))
        id += 1
    }

    entries.append(.header(240, .tabs, strings.tabsHeader))
    entries.append(.flag(241, .tabs, .showContactsTab, strings.showContactsTab, !state.hideContactsTab))
    entries.append(.flag(242, .tabs, .showCallsTab, strings.showCallsTab, showCallsTab))
    entries.append(.flag(243, .tabs, .showTabTitles, strings.showTabTitles, !state.hideTabTitles))

    entries.append(.header(260, .location, strings.locationHeader))
    if let latitude = state.emulatedLatitude, let longitude = state.emulatedLongitude {
        entries.append(.info(261, .location, strings.locationOn(latitude, longitude)))
        entries.append(.action(262, .location, .disableLocation, strings.locationDisable))
    } else {
        entries.append(.info(261, .location, strings.locationOff))
    }
    entries.append(.footer(279, .location, strings.locationFooter))

    entries.append(.header(280, .duress, strings.duressHeader))
    entries.append(.action(281, .duress, .setDuress, state.duressSet ? strings.duressChange : strings.duressSet))
    if state.duressSet {
        entries.append(.action(282, .duress, .clearDuress, strings.duressClear))
    }
    entries.append(.choice(283, .duress, .duressAction(.logout), strings.duressLogout, state.duressAction == .logout))
    entries.append(.choice(284, .duress, .duressAction(.deleteAccounts), strings.duressDelete, state.duressAction == .deleteAccounts))
    entries.append(.footer(299, .duress, strings.duressFooter))

    entries.append(.header(300, .tools, strings.toolsHeader))
    entries.append(.action(301, .tools, .exportChat, strings.exportChat))
    entries.append(.footer(319, .tools, strings.exportFooter))

    entries.append(.header(320, .network, strings.networkHeader))
    entries.append(.toggle(321, .network, .blockSponsored, strings.label(.blockSponsored), state.value(.blockSponsored)))
    entries.append(.footer(350, .network, strings.networkFooter))

    return entries
}

private func ilvStartChatExport(context: AccountContext, peerId: EnginePeer.Id, controller: ViewController?) {
    let strings = IlvStrings()
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let disposable = MetaDisposable()
    let progress = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
        disposable.dispose()
    }))
    controller?.present(progress, in: .window(.root))

    disposable.set((ilvExportChat(account: context.account, peerId: peerId)
    |> deliverOnMainQueue).start(next: { [weak progress, weak controller] event in
        switch event {
        case .progress:
            break
        case let .completed(url):
            progress?.dismiss()
            let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let view = controller?.view {
                activityController.popoverPresentationController?.sourceView = view
                activityController.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1.0, height: 1.0)
            }
            context.sharedContext.applicationBindings.presentNativeController(activityController)
        case .failed:
            progress?.dismiss()
            controller?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: strings.exportTitle, text: strings.exportFailed, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
                return false
            }), in: .window(.root))
        }
    }))
}

/// Asks for the fake passcode twice in a native alert.
private func ilvPresentDuressPrompt(context: AccountContext, completion: @escaping (Bool) -> Void) {
    let strings = IlvStrings()
    let alert = UIAlertController(title: strings.duressPromptTitle, message: strings.duressPromptText, preferredStyle: .alert)
    for _ in 0 ..< 2 {
        alert.addTextField(configurationHandler: { textField in
            textField.isSecureTextEntry = true
            textField.keyboardType = .asciiCapable
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
        })
    }
    alert.addAction(UIAlertAction(title: strings.cancel, style: .cancel, handler: { _ in
        completion(false)
    }))
    alert.addAction(UIAlertAction(title: strings.save, style: .default, handler: { [weak alert] _ in
        let first = alert?.textFields?.first?.text ?? ""
        let second = alert?.textFields?.last?.text ?? ""
        if first.isEmpty || first != second {
            completion(false)
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: strings.duressMismatch, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
                return false
            }), on: .root, blockInteraction: false, completion: {})
            return
        }
        IlvDuress.set(code: first)
        completion(true)
    }))
    context.sharedContext.applicationBindings.presentNativeController(alert)
}

private func ilvSettingsController(context: AccountContext) -> ViewController {
    let strings = IlvStrings()
    let statePromise = ValuePromise(IlvPrivacyState.current(), ignoreRepeated: true)
    let refresh = {
        statePromise.set(IlvPrivacyState.current())
    }

    var pushControllerImpl: ((ViewController) -> Void)?
    var exportImpl: ((EnginePeer.Id) -> Void)?
    var showToastImpl: ((String) -> Void)?

    let accountManager = context.sharedContext.accountManager
    let showCallsTab: Signal<Bool, NoError> = accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings])
    |> map { sharedData -> Bool in
        return (sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? CallListSettings.defaultSettings).showTab
    }
    |> distinctUntilChanged

    let arguments = IlvPrivacyControllerArguments(toggle: { option, value in
        IlvPrivacy.setEnabled(option, value)
        refresh()
    }, setGhostMode: { value in
        IlvPrivacy.setGhostModeEnabled(value)
        refresh()
    }, setFlag: { flag, value in
        switch flag {
        case .showContactsTab:
            IlvTabs.hideContacts = !value
        case .showTabTitles:
            IlvTabs.hideTitles = !value
        case .showCallsTab:
            let _ = updateCallListSettingsInteractively(accountManager: accountManager, { settings in
                return settings.withUpdatedShowTab(value)
            }).start()
        }
        refresh()
    }, choose: { choice in
        switch choice {
        case let .voice(preset):
            IlvVoicePreset.current = preset
        case let .bubbleAlpha(value):
            IlvAppearance.bubbleAlpha = value
        case let .duressAction(action):
            IlvDuress.action = action
        }
        refresh()
    }, perform: { action in
        switch action {
        case .resetChats:
            IlvGhost.resetPeerOverrides()
            refresh()
        case .clearDeletedMarks:
            IlvDeletedMessages.clearMarks()
            refresh()
        case .exportChat:
            let selection = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.doNotSearchMessages], hasContactSelector: false, title: strings.exportTitle))
            selection.peerSelected = { [weak selection] peer, _ in
                selection?.dismiss()
                exportImpl?(peer.id)
            }
            pushControllerImpl?(selection)
        case .disableLocation:
            IlvLocationEmulation.disable()
            refresh()
        case .setDuress:
            ilvPresentDuressPrompt(context: context, completion: { saved in
                refresh()
                if saved {
                    showToastImpl?(strings.duressSaved)
                }
            })
        case .clearDuress:
            IlvDuress.clear()
            refresh()
        case .clearEditHistory:
            IlvEditHistory.clear()
            refresh()
        }
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get(), showCallsTab)
    |> deliverOnMainQueue
    |> map { presentationData, state, showCallsTab -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: ilvPrivacyEntries(state: state, showCallsTab: showCallsTab), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { _ in
        // Per-chat ghost switches, deleted marks and location emulation change outside this screen.
        refresh()
    }
    pushControllerImpl = { [weak controller] c in
        guard let controller = controller else {
            return
        }
        if let navigationController = controller.navigationController as? NavigationController {
            navigationController.pushViewController(c)
        } else if let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController {
            navigationController.pushViewController(c)
        }
    }
    exportImpl = { [weak controller] peerId in
        ilvStartChatExport(context: context, peerId: peerId, controller: controller)
    }
    showToastImpl = { [weak controller] text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
            return false
        }), in: .current)
    }
    return controller
}

/// Settings → "ilvtg", and Settings → Privacy and Security → "ilvtg Privacy".
public func ilvPrivacyController(context: AccountContext) -> ViewController {
    return ilvSettingsController(context: context)
}
