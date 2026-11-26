// ilvtg — chat export to a plain-text file.
// Copied into submodules/TelegramCore/Sources/Ilv/ by ci/prepare.py.
//
// Walks the whole history with messages.getHistory (100 per request, newest first), the same
// request the official client uses to fill history holes, and writes it oldest first.

import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

public enum IlvChatExportEvent {
    case progress(Int)
    case completed(URL)
    case failed
}

private final class IlvChatExportState: @unchecked Sendable {
    let disposable = MetaDisposable()
    var lines: [String] = []
    var count = 0
    var cancelled = false
}

private func ilvPeerName(_ peer: Peer?) -> String {
    guard let peer = peer else {
        return "?"
    }
    if let user = peer as? TelegramUser {
        let name = [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty {
            return name
        }
        if let username = user.username, !username.isEmpty {
            return "@" + username
        }
        return "Deleted Account"
    }
    if let group = peer as? TelegramGroup {
        return group.title
    }
    if let channel = peer as? TelegramChannel {
        return channel.title
    }
    return "?"
}

private func ilvMediaDescription(_ media: Media, ru: Bool) -> String {
    if media is TelegramMediaImage {
        return ru ? "[Фото]" : "[Photo]"
    }
    if let file = media as? TelegramMediaFile {
        if file.isVoice {
            return ru ? "[Голосовое сообщение]" : "[Voice message]"
        }
        if file.isInstantVideo {
            return ru ? "[Видеосообщение]" : "[Video message]"
        }
        if file.isSticker || file.isAnimatedSticker {
            return ru ? "[Стикер]" : "[Sticker]"
        }
        if file.isVideo {
            return ru ? "[Видео]" : "[Video]"
        }
        if file.isMusic {
            return ru ? "[Аудио]" : "[Audio]"
        }
        let name = file.fileName ?? ""
        return (ru ? "[Файл" : "[File") + (name.isEmpty ? "]" : ": \(name)]")
    }
    if media is TelegramMediaAction {
        return ru ? "[Служебное сообщение]" : "[Service message]"
    }
    return ru ? "[Медиа]" : "[Media]"
}

private func ilvFormatMessage(_ message: Message, formatter: DateFormatter, ru: Bool) -> String {
    let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.timestamp)))
    var header = "[\(date)] \(ilvPeerName(message.author))"
    if let forwardInfo = message.forwardInfo {
        header += ru ? " (переслано от \(ilvPeerName(forwardInfo.author)))" : " (forwarded from \(ilvPeerName(forwardInfo.author)))"
    }
    var parts: [String] = []
    for media in message.media {
        parts.append(ilvMediaDescription(media, ru: ru))
    }
    if !message.text.isEmpty {
        parts.append(message.text)
    }
    return header + ":\n" + parts.joined(separator: "\n") + "\n"
}

private func ilvSafeFileName(_ value: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
    let cleaned = value.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "chat" : String(cleaned.prefix(60))
}

/// Exports the whole chat. Emits progress (number of messages) and finally the file URL.
public func ilvExportChat(account: Account, peerId: PeerId, maxMessages: Int = 200000) -> Signal<IlvChatExportEvent, NoError> {
    let ru = (Locale.preferredLanguages.first ?? "").hasPrefix("ru")
    return account.postbox.transaction { transaction -> Peer? in
        return transaction.getPeer(peerId)
    }
    |> mapToSignal { peer -> Signal<IlvChatExportEvent, NoError> in
        guard let peer = peer, let inputPeer = apiInputPeer(peer) else {
            return .single(.failed)
        }
        return Signal { subscriber in
            let state = IlvChatExportState()
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
            let accountPeerId = account.peerId
            let peerIsForum = peer.isForum

            func finish() {
                if state.cancelled {
                    return
                }
                let title = ilvPeerName(peer)
                var text = (ru ? "Экспорт чата: " : "Chat export: ") + title + "\n"
                text += (ru ? "Сообщений: " : "Messages: ") + "\(state.count)\n"
                text += (ru ? "Создано в ilvtg " : "Created by ilvtg ") + formatter.string(from: Date()) + "\n\n"
                text += state.lines.reversed().joined(separator: "\n")

                let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ilvtg-export", isDirectory: true)
                let _ = try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                let url = directory.appendingPathComponent(ilvSafeFileName(title) + ".txt")
                do {
                    try text.data(using: .utf8)?.write(to: url, options: .atomic)
                    subscriber.putNext(.completed(url))
                } catch {
                    subscriber.putNext(.failed)
                }
                subscriber.putCompletion()
            }

            func step(offsetId: Int32) {
                let request = account.network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: offsetId, offsetDate: 0, addOffset: 0, limit: 100, maxId: 0, minId: 0, hash: 0))
                state.disposable.set((request
                |> delay(offsetId == 0 ? 0.0 : 0.35, queue: Queue.concurrentDefaultQueue())).start(next: { result in
                    var apiMessages: [Api.Message] = []
                    var apiChats: [Api.Chat] = []
                    var apiUsers: [Api.User] = []
                    switch result {
                    case let .messages(messagesData):
                        apiMessages = messagesData.messages
                        apiChats = messagesData.chats
                        apiUsers = messagesData.users
                    case let .messagesSlice(messagesSliceData):
                        apiMessages = messagesSliceData.messages
                        apiChats = messagesSliceData.chats
                        apiUsers = messagesSliceData.users
                    case let .channelMessages(channelMessagesData):
                        apiMessages = channelMessagesData.messages
                        apiChats = channelMessagesData.chats
                        apiUsers = channelMessagesData.users
                    case .messagesNotModified:
                        break
                    }

                    var peers: [PeerId: Peer] = [:]
                    for chat in apiChats {
                        if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                            peers[groupOrChannel.id] = groupOrChannel
                        }
                    }
                    for user in apiUsers {
                        let telegramUser = TelegramUser(user: user)
                        peers[telegramUser.id] = telegramUser
                    }

                    var minId: Int32 = Int32.max
                    var added = 0
                    for apiMessage in apiMessages {
                        guard let storeMessage = StoreMessage(apiMessage: apiMessage, accountPeerId: accountPeerId, peerIsForum: peerIsForum) else {
                            continue
                        }
                        if case let .Id(id) = storeMessage.id {
                            minId = min(minId, id.id)
                        }
                        if let message = locallyRenderedMessage(message: storeMessage, peers: peers) {
                            state.lines.append(ilvFormatMessage(message, formatter: formatter, ru: ru))
                            added += 1
                        }
                    }
                    state.count += added
                    subscriber.putNext(.progress(state.count))

                    if apiMessages.isEmpty || minId == Int32.max || minId <= 1 || state.count >= maxMessages || state.cancelled {
                        finish()
                    } else {
                        step(offsetId: minId)
                    }
                }, error: { _ in
                    if state.count > 0 {
                        finish()
                    } else {
                        subscriber.putNext(.failed)
                        subscriber.putCompletion()
                    }
                }))
            }

            step(offsetId: 0)

            return ActionDisposable {
                state.cancelled = true
                state.disposable.dispose()
            }
        }
    }
}
