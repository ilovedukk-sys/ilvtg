# ilvtg

Неофициальный клиент Telegram для iPhone с упором на приватность и экономию ресурсов.

ilvtg — самостоятельный проект. В репозитории только наш код: Swift-модули в `src/` и скрипт
`ci/prepare.py`, который накладывает наши правки на **официальный** исходный код
[Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) (коммит закреплён в
`upstream.json`). От сторонних форков сборка не зависит. Идеи частично взяты у
[VoidGram](https://github.com/neosay-dev/VoidGram), но их код здесь не используется.

## Что изменено

### Режим призрака (Настройки → Конфиденциальность → «Приватность ilvtg»)
Каждую опцию можно включить отдельно, по умолчанию все выключены.

| Опция | Что не уходит на сервер |
|---|---|
| Не отправлять «прочитано» | `messages.readHistory`, `channels.readHistory`, `messages.readDiscussion`, `read*MessageContents`, `readEncryptedHistory` |
| Смотреть истории незаметно | `stories.readStories`, `stories.incrementStoryViews` |
| Не показывать «в сети» | `account.updateStatus` |
| Не показывать «печатает…» | `messages.setTyping`, `messages.setEncryptedTyping` |

Ограничения: если вы отправите сообщение в чат, сервер Telegram всё равно отметит его
прочитанным. После выключения опции следующее прочтение подтвердит и все предыдущие сообщения.
Telegram считает такие функции нарушением [API ToS](https://core.telegram.org/api/terms),
поэтому используйте их на свой риск.

### Всегда
- **Телеметрия не отправляется:** `help.saveAppLog` (журнал событий приложения),
  `phone.saveCallDebug` и `phone.saveCallLog` (отладочные логи звонков).
- **Реклама в каналах и промо-канал прокси** не запрашиваются (переключатель, по умолчанию включён).

### Приватные настройки по умолчанию
- Синхронизация контактов выключена, в том числе сразу после входа (включается в
  Конфиденциальность → Настройки данных).
- CallKit выключен: звонки не попадают в «Недавние» iOS и в iCloud.
- Чаты и контакты не передаются в Siri, Spotlight и подсказки меню «Поделиться».
- Входящие сообщения не передаются в Siri.

### Оптимизация
- Release-сборка arm64 без dSYM.
- Без расширений (виджет, Siri, «Поделиться», уведомления, демонстрация экрана): IPA меньше,
  а при sideload нужен один App ID вместо семи. Вернуть их можно через `app_extensions: true`
  в `app.json`.
- Через сотовую сеть по умолчанию стоит профиль автозагрузки «низкий».

Как это работает: все запросы MTProto проходят через `Network.request`. Правка
`network-guard` проверяет имя метода по спискам из
[`src/TelegramCore/IlvPrivacy.swift`](src/TelegramCore/IlvPrivacy.swift) и не отправляет
заблокированные. Все точки вызова этих методов в Telegram-iOS обрабатывают ошибку без повторов,
мы проверили это на закреплённом коммите.

## Сборка в GitHub Actions

1. Получите `api_id` и `api_hash` на <https://my.telegram.org/apps>.
2. Добавьте их в секреты репозитория (Settings → Secrets and variables → Actions):
   `TELEGRAM_API_ID` и `TELEGRAM_API_HASH`. Без них приложение соберётся, но войти не получится.
3. Сборка запускается при каждом push в `main` (или вручную: Actions → iOS build → Run workflow).
   Сначала около 2 минут идёт проверка того, что все правки применяются, затем полная сборка
   на раннере `xcode-27` (macOS 27, Xcode 27.1), она занимает 1,5–3 часа.
4. Готовый `ilvtg.ipa` появится в артефактах запуска (хранится 7 дней).

## Установка на iPhone

IPA **не подписан**. Установить его можно так:
- [Sideloadly](https://sideloadly.io/) или AltStore/SideStore с бесплатным Apple ID
  (приложение придётся переподписывать каждые 7 дней);
- платным сертификатом разработчика;
- через TrollStore, если ваша версия iOS его поддерживает.

Инструменты sideload при переподписи часто убирают entitlement App Group. Официальный Telegram
в этом случае зависает на чёрном экране. ilvtg тогда хранит данные в собственной папке внутри
песочницы приложения (Application Support, исключена из бэкапа iCloud). Код-пароль на экран
блокировки в такой установке может не сохраняться, потому что связке ключей тоже нужна App Group.

Push-уведомления в самостоятельно собранной версии не работают: Telegram отправляет их
только на сертификат официального приложения. Пока приложение открыто или работает в фоне,
сообщения приходят.

⚠️ `api_hash` зашит в IPA. В публичном репозитории артефакты может скачать любой
пользователь GitHub, поэтому не раздавайте сборки посторонним.

## Локальная сборка (macOS)

```bash
git clone https://github.com/TelegramMessenger/Telegram-iOS.git telegram
git -C telegram checkout $(python3 -c 'import json;print(json.load(open("upstream.json"))["commit"])')
python3 ci/prepare.py telegram
git -C telegram submodule update --init --recursive --depth=1
bash ci/macos_setup.sh telegram
TELEGRAM_API_ID=... TELEGRAM_API_HASH=... python3 ci/build.py telegram --cache-dir ~/.ilvtg-cache --out out
```

## Обновление базы Telegram

Поменяйте `commit` в `upstream.json` и запушьте. Если какая-то правка перестанет совпадать
с новым кодом, задача `patches` упадёт с именем правки и файлом. Исправьте фрагмент в
`ci/prepare.py`.

## Лицензия

GPL-2.0, как и Telegram-iOS: см. [LICENSE](LICENSE). Распространяя IPA, вы обязаны
предоставить исходный код, и этот репозиторий выполняет это требование.
