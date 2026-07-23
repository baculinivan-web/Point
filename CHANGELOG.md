# Changelog

## 0.1.1 — Public Beta

- Добавлены изолированные приватные окна (`⌘⇧N`) без persistent browsing data.
- Session и browsing history переведены на SwiftData с одноразовой миграцией JSON.
- Добавлен live transfer выбранных вкладок в новое обычное окно без reload.
- Добавлена автоматическая очистка WebKit cache раз в 7 дней и истории старше 90 дней.
- Добавлен production release pipeline: Developer ID, Hardened Runtime, timestamp, Apple notarization, stapling и Gatekeeper verification.
- Версия bundle обновлена до `0.1.1` (`23`).

Known limitation: нативный trackpad swipe стабилен внутри текущего WebKit process history. На границе логической истории, восстановленной после restart, гарантированы кнопки Back/Forward и `⌘[`/`⌘]`; swipe может быть менее предсказуемым.
