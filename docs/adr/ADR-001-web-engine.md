# ADR-001: `WKWebView` как движок MVP

- Статус: принято
- Дата: 2026-07-22

## Контекст

Browser требует вкладки, popup-навигацию, полный navigation policy, восстановление после завершения Web Content process и точный контроль жизненного цикла web view. Эти возможности важнее более короткого SwiftUI-only прототипа.

## Решение

Использовать один `WKWebView` на live-вкладку и минимальный `NSViewRepresentable`-host. В SwiftUI-иерархию прикрепляется только активный web view. Восстановленные вкладки остаются metadata-only до первого выбора.

## Последствия

- Delegate/KVO-слой инкапсулирован в `BrowserEngine`.
- Popup создаётся с конфигурацией, которую передал WebKit.
- Фоновая вкладка не обязана занимать память сразу после восстановления сессии.
- Downloads, permission queue и `interactionState` eviction добавляются после MVP без замены host-архитектуры.
