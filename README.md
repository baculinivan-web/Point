# Point 0.1.1 Public Beta

Нативный минималистичный браузер для macOS 26 на Swift 6, SwiftUI и WebKit. Реализация следует продуктовым принципам из [PRODUCT_VISION.md](docs/PRODUCT_VISION.md) и архитектурным границам из [IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md).

## Что уже работает

- настоящее web-содержимое через `WKWebView`;
- несколько вкладок без reload при обычном переключении;
- несколько обычных окон и перенос выбранных вкладок в новое окно без reload: живой `WKWebView`, media и scroll state меняют владельца вместе с вкладкой;
- приватные окна по `⌘⇧N` с отдельным non-persistent WebKit store, memory-only session/history/permissions/download list/favicon cache и без восстановления после закрытия;
- системные двухпальцевые горизонтальные gestures для нативной истории текущего процесса;
- восстановление вкладок после перезапуска вместе с persisted back/forward stack до 50 committed переходов на tab;
- Back/Forward и `⌘[`/`⌘]` после restart загружают выбранную старую страницу только по действию пользователя, без фонового replay сетевых запросов;
- cold eviction фоновых вкладок с in-process восстановлением через `WKWebView.interactionState` и fallback на последний URL;
- lifecycle-состояния active/live/suspended/evicted/restoring/crashed, LRU и адаптивный resident budget для 8/16/24–32/>32 GB;
- memory-pressure и thermal/app-activity reconcile без постоянного polling;
- парные suspend/resume media и защита active, playing-media, camera/microphone, fullscreen и незавершённых native dialog/file flows;
- omnibox с безопасной классификацией URL/поискового запроса;
- локальный поиск по открытым вкладкам;
- back, forward, reload, reload без кэша и stop;
- `target=_blank`/`window.open` в новой вкладке с WebKit configuration;
- новая, закрытие и восстановление последней закрытой вкладки;
- закрепление и drag-and-drop сортировка вкладок;
- сохраняемые папки вкладок с неограниченной вложенностью, SF Symbols-значками, переименованием, Shift-выделением диапазона, групповым переносом и рекурсивным удалением;
- три состояния sidebar: pinned с зарезервированным viewport, hidden и временный Liquid Glass overlay без изменения viewport;
- поиск по странице;
- file input и JavaScript alert/confirm/text prompt;
- сериализованная очередь camera/microphone permissions: запрос фоновой вкладки ждёт её выбора, navigation/close безопасно отменяют handler, а prompt предлагает разрешить один раз, всегда или запретить;
- постоянные camera/microphone decisions по нормализованному origin в отдельном атомарном JSON; persistent allow доступен только для HTTPS, subframe и top-level origins показываются раздельно;
- управление сохранёнными site permissions через пункт «Разрешения сайтов…» в меню приложения: список allow/deny, отзыв отдельного решения и очистка всех; отзыв active allow прекращает текущий WebKit capture этого origin;
- HTTP Basic/Digest authentication с нативным credential prompt без сохранения пароля;
- подтверждение перед открытием `mailto`, `tel` и `facetime`; неизвестные внешние схемы блокируются;
- passkeys из Keychain/совместимых credential providers через системный WebKit WebAuthn flow; браузер запрашивает доступ до создания первой страницы, а повторная проверка доступна в меню приложения;
- favicon discovery после завершения навигации, origin-keyed memory/disk cache и deterministic fallback-иконка;
- общая локальная история посещений: запись после main-frame commit, обновление title после finish, объединение быстрых дублей, лимит 5000 записей и окно «История» по `⌘Y`;
- строки истории переиспользуют origin-keyed favicon cache только в cache-only режиме и не создают сетевые запросы при открытии списка;
- независимая очистка history, cookies, web cache, local storage/IndexedDB/WebSQL, service workers, site permissions, download history и favicon cache через `⌘⇧⌫`; активные загрузки при этом сохраняются;
- автоматическая maintenance-очистка раз в 7 дней: WebKit cache и записи истории старше 90 дней;
- регистрация `http/https`, приём внешних URL и явная команда назначения браузером по умолчанию в меню приложения;
- обычные, attachment и unsupported-MIME загрузки через `WKDownload`: автоматическое сохранение в системную папку `Загрузки`, безопасный filename/collision suffix, progress, cancel/resume и сохранение resume data;
- компактный Liquid Glass progress bubble сверху слева; hover показывает крестик, скрывающий индикатор без отмены загрузки;
- downloads view внутри sidebar: кнопка справа в верхнем toolbar или `⌘⇧J`, progress, очистка списка и reveal завершённого файла в Finder;
- единый для всех окон DownloadManager и атомарная история последних 200 завершённых/отменённых/ошибочных загрузок между запусками без source URL, query и resume data;
- системное подтверждение выхода при активных загрузках; подтверждённый quit сначала flush-ит поставленную в очередь download history;
- восстановление URL, title, порядка и режима sidebar;
- session и browsing history в SwiftData с одноразовой миграцией прежних `session.json`/`history.json` в файлы `.migrated`;
- системные shortcuts и accessibility labels;
- нативный Liquid Glass с Reduce Transparency/Reduce Motion fallback.

## Запуск

Требования: macOS 26+, Xcode 26+.

```bash
make test
make run
```

`make run` собирает локально подписанный app bundle в `dist/Point.app`. Проект также можно открыть в Xcode как Swift Package через `Package.swift`.

Production release требует сертификат Developer ID Application и заранее сохранённый профиль `notarytool`:

```bash
xcrun notarytool store-credentials point-notary
NOTARY_PROFILE=point-notary make release
```

Release pipeline собирает `release`, включает Hardened Runtime и secure timestamp, проверяет подпись, отправляет zip в Apple, stapling-ит ticket и выполняет финальные `stapler`/Gatekeeper checks. Без Developer ID identity или notary profile скрипт завершается до публикации.

Для ручной проверки download и camera без внешних сайтов:

```bash
python3 scripts/manual-test-server.py
```

После запуска открыть в Browser `http://localhost:8765`. Download автоматически сохраняется в системную папку `Загрузки`; медленный fixture позволяет увидеть круговой progress bubble сверху слева и проверить предупреждение по `⌘Q`. Завершённая запись остаётся в downloads view после перезапуска. Camera должна сначала показать Liquid Glass prompt Browser с origin, затем системный запрос macOS и превью. Постоянный camera/microphone badge не показывается. Для локального HTTP fixture доступно только разрешение на один раз; постоянный allow намеренно включён только для HTTPS. Сохранённые решения доступны через «Разрешения сайтов…» в меню приложения. На странице также есть JavaScript prompt, HTTP Basic auth (`browser` / `test`) и `mailto` confirmation.

## Структура

- `BrowserCore` — чистые модели, команды и omnibox parser;
- `BrowserEngine` — `WKWebView`, delegates и SwiftUI host;
- `BrowserPersistence` — атомарное хранение session, permissions, browsing/download history вне main actor;
- `BrowserUI` — window model, sidebar, omnibox и design system;
- `BrowserApp` — composition root и scenes.

## Состояние public beta

MVP и основной Phase 4 lifecycle-контур реализованы. Lifecycle policy покрыта unit-тестами; eviction/restore размечены signpost-интервалами. `interactionState` намеренно хранится только в памяти процесса. Для restart отдельно сохраняется безопасный логический URL/title stack вкладки: он восстанавливает доступность Back/Forward, но не архивирует form/scroll state и не выполняет старые запросы до команды пользователя.

Ограничения текущего Phase 4: playback protection консервативно считает любое состояние WebKit `.playing` защищённым (отдельного надёжного public API для audible-only нет); WebAuthn/payment flow пока не имеет отдельного protected reason; pressure и 100-cycle memory exit criteria требуют ручного Instruments-прогона на реальном M1 8 GB и не заявлены как пройденные.

Phase 5 продолжен download pipeline, нативными web-dialog/auth flows и полной camera/microphone permission queue. Media completion handlers завершаются ровно один раз; запросы фоновых вкладок откладываются, stale origin отменяется на navigation, а persistent decisions изолированы по origin и типу ресурса. Загрузка после передачи в `WKDownload` не зависит от жизни исходной вкладки; app-scoped DownloadManager поддерживает cancel/resume, reveal, безопасную persistent history и quit-confirmation.

Минимальная история посещений и Clear Browsing Data из Phase 5 реализованы. Session и browsing history хранятся в SwiftData; download history остаётся в `downloads.json`, site decisions — в `permissions.json`; favicon являются пересоздаваемыми данными и остаются в `Caches/Browser/Favicons`. Ручная очистка использует точный период «за всё время»; maintenance дополнительно удаляет историю старше 90 дней и WebKit cache раз в 7 дней. Выбор произвольного периода остаётся дальнейшим расширением.

Ограничения текущего Phase 5: остаётся локальная integration-проверка OAuth popup, blob download, fullscreen и TLS flows. После удаления WebKit data live-вкладки перезагружаются; очистка download history намеренно не отменяет активные загрузки.

Public-beta scope закрывает private windows, SwiftData migration, multiple-window live tab transfer, периодическую очистку и воспроизводимый production signing/notarization pipeline.

Известное ограничение 0.1.1: двухпальцевый swipe надёжно использует нативный список WebKit текущего процесса; после restart восстановленный логический Back/Forward stack доступен кнопками и `⌘[`/`⌘]`, но trackpad swipe на самой persisted-границе может быть менее предсказуемым. Старые страницы по-прежнему не загружаются в фоне и открываются только по действию пользователя.

Приватный режим не делает пользователя анонимным для сайтов, сети, работодателя или интернет-провайдера. Он гарантирует локальную изоляцию окна и освобождение его runtime после закрытия, но загруженные по явному действию файлы остаются на диске.
