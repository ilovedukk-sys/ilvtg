// ilvtg — settings screen. Shown as its own tab in the root tab bar and also reachable from
// Settings → Privacy and Security → first row.
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

private final class IlvPrivacyControllerArguments {
    let toggle: (IlvPrivacyOption, Bool) -> Void
    let setGhostMode: (Bool) -> Void
    let setVoicePreset: (IlvVoicePreset) -> Void
    let resetChats: () -> Void
    let clearDeletedMarks: () -> Void
    let exportChat: () -> Void

    init(toggle: @escaping (IlvPrivacyOption, Bool) -> Void, setGhostMode: @escaping (Bool) -> Void, setVoicePreset: @escaping (IlvVoicePreset) -> Void, resetChats: @escaping () -> Void, clearDeletedMarks: @escaping () -> Void, exportChat: @escaping () -> Void) {
        self.toggle = toggle
        self.setGhostMode = setGhostMode
        self.setVoicePreset = setVoicePreset
        self.resetChats = resetChats
        self.clearDeletedMarks = clearDeletedMarks
        self.exportChat = exportChat
    }
}

private enum IlvPrivacySection: Int32 {
    case ghost
    case messages
    case voice
    case media
    case tools
    case network
}

private enum IlvPrivacyAction: Equatable {
    case resetChats
    case clearDeletedMarks
    case exportChat
}

private enum IlvPrivacyEntry: ItemListNodeEntry {
    case header(Int32, IlvPrivacySection, String)
    case ghostMaster(Int32, String, Bool)
    case toggle(Int32, IlvPrivacySection, IlvPrivacyOption, String, Bool)
    case voice(Int32, IlvVoicePreset, String, Bool)
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
        case .voice:
            return IlvPrivacySection.voice.rawValue
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
        case let .voice(id, _, _, _):
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
        case let .voice(lhsId, lhsPreset, lhsText, lhsValue):
            if case let .voice(rhsId, rhsPreset, rhsText, rhsValue) = rhs, lhsId == rhsId, lhsPreset == rhsPreset, lhsText == rhsText, lhsValue == rhsValue {
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
        case let .voice(_, preset, text, value):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: text, style: .left, checked: value, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setVoicePreset(preset)
            })
        case let .action(_, _, action, text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: action == .exportChat ? .generic : .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                switch action {
                case .resetChats:
                    arguments.resetChats()
                case .clearDeletedMarks:
                    arguments.clearDeletedMarks()
                case .exportChat:
                    arguments.exportChat()
                }
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

    static func current() -> IlvPrivacyState {
        var values: [IlvPrivacyOption: Bool] = [:]
        for option in IlvPrivacyOption.allCases {
            values[option] = IlvPrivacy.isEnabled(option)
        }
        return IlvPrivacyState(values: values, voicePreset: IlvVoicePreset.current, overriddenChats: IlvGhost.overriddenChatCount, deletedMarks: IlvDeletedMessages.count)
    }

    func value(_ option: IlvPrivacyOption) -> Bool {
        return self.values[option] ?? option.defaultValue
    }
}

private func ilvPrivacyEntries(state: IlvPrivacyState) -> [IlvPrivacyEntry] {
    let strings = IlvStrings()
    var entries: [IlvPrivacyEntry] = []

    entries.append(.header(0, .ghost, strings.ghostHeader))
    entries.append(.ghostMaster(1, strings.ghostMaster, IlvPrivacyOption.ghostOptions.allSatisfy { state.value($0) }))
    var id: Int32 = 2
    for option in IlvPrivacyOption.ghostOptions + [.showChatGhostButton] {
        entries.append(.toggle(id, .ghost, option, strings.label(option), state.value(option)))
        id += 1
    }
    if state.overriddenChats > 0 {
        entries.append(.action(18, .ghost, .resetChats, strings.resetChats(state.overriddenChats)))
    }
    entries.append(.footer(19, .ghost, strings.ghostFooter))

    entries.append(.header(20, .messages, strings.messagesHeader))
    entries.append(.toggle(21, .messages, .keepDeletedMessages, strings.label(.keepDeletedMessages), state.value(.keepDeletedMessages)))
    entries.append(.toggle(22, .messages, .keepSelfDestructing, strings.label(.keepSelfDestructing), state.value(.keepSelfDestructing)))
    entries.append(.toggle(23, .messages, .replayViewOnce, strings.label(.replayViewOnce), state.value(.replayViewOnce)))
    if state.deletedMarks > 0 {
        entries.append(.action(38, .messages, .clearDeletedMarks, strings.clearDeletedMarks(state.deletedMarks)))
    }
    entries.append(.footer(39, .messages, strings.messagesFooter))

    entries.append(.header(40, .voice, strings.voiceHeader))
    id = 41
    for preset in IlvVoicePreset.allCases {
        entries.append(.voice(id, preset, strings.label(preset), state.voicePreset == preset))
        id += 1
    }

    entries.append(.header(60, .media, strings.mediaHeader))
    entries.append(.toggle(61, .media, .blurFacesInVideoMessages, strings.label(.blurFacesInVideoMessages), state.value(.blurFacesInVideoMessages)))
    entries.append(.footer(79, .media, strings.mediaFooter))

    entries.append(.header(80, .tools, strings.toolsHeader))
    entries.append(.action(81, .tools, .exportChat, strings.exportChat))
    entries.append(.footer(99, .tools, strings.exportFooter))

    entries.append(.header(100, .network, strings.networkHeader))
    entries.append(.toggle(101, .network, .blockSponsored, strings.label(.blockSponsored), state.value(.blockSponsored)))
    entries.append(.footer(150, .network, strings.networkFooter))

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

private func ilvSettingsController(context: AccountContext, isTab: Bool) -> ViewController {
    let strings = IlvStrings()
    let statePromise = ValuePromise(IlvPrivacyState.current(), ignoreRepeated: true)
    let refresh = {
        statePromise.set(IlvPrivacyState.current())
    }

    var pushControllerImpl: ((ViewController) -> Void)?
    var exportImpl: ((EnginePeer.Id) -> Void)?

    let arguments = IlvPrivacyControllerArguments(toggle: { option, value in
        IlvPrivacy.setEnabled(option, value)
        refresh()
    }, setGhostMode: { value in
        IlvPrivacy.setGhostModeEnabled(value)
        refresh()
    }, setVoicePreset: { preset in
        IlvVoicePreset.current = preset
        refresh()
    }, resetChats: {
        IlvGhost.resetPeerOverrides()
        refresh()
    }, clearDeletedMarks: {
        IlvDeletedMessages.clearMarks()
        refresh()
    }, exportChat: {
        let selection = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.doNotSearchMessages], hasContactSelector: false, title: strings.exportTitle))
        selection.peerSelected = { [weak selection] peer, _ in
            selection?.dismiss()
            exportImpl?(peer.id)
        }
        pushControllerImpl?(selection)
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: isTab ? nil : ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: ilvPrivacyEntries(state: state), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let tabBarItem: Signal<ItemListControllerTabBarItem, NoError>?
    if isTab {
        let icon = ilvGhostImage(color: .black, size: 28.0, crossed: false).withRenderingMode(.alwaysTemplate)
        tabBarItem = .single(ItemListControllerTabBarItem(title: strings.title, image: icon, selectedImage: icon))
    } else {
        tabBarItem = nil
    }

    let controller = ItemListController(context: context, state: signal, tabBarItem: tabBarItem)
    controller.didAppear = { _ in
        // Per-chat ghost switches and deleted marks change outside this screen.
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
    return controller
}

/// Settings → Privacy and Security → "ilvtg Privacy".
public func ilvPrivacyController(context: AccountContext) -> ViewController {
    return ilvSettingsController(context: context, isTab: false)
}

/// The "ilvtg" tab in the root tab bar.
public func ilvSettingsTabController(context: AccountContext) -> ViewController {
    return ilvSettingsController(context: context, isTab: true)
}
