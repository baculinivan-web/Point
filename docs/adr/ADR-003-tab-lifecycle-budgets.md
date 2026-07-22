# ADR-003: lifecycle вкладок и resident budget

- Статус: принято
- Дата: 2026-07-22

## Контекст

Metadata-only session restore ограничивает стартовую стоимость, но длительная сессия всё равно может удерживать отдельный `WKWebView` для каждой когда-либо выбранной вкладки. Частные WebKit API и постоянный polling памяти недопустимы.

## Решение

- Resident budget включает active и фоновые live/suspended вкладки: 2 для 8 GB, 4 для 16 GB, 7 для 24–32 GB и 10 выше 32 GB.
- Warning, inactive app и серьёзный thermal state уменьшают budget; critical pressure оставляет active и явно protected вкладки.
- LRU использует время последней активации. Новая/только что покинутая вкладка получает grace period.
- Допустимая idle background вкладка suspend-ится парным `setAllMediaPlaybackSuspended`; при выборе выполняется resume.
- Перед eviction opaque `interactionState` остаётся только в памяти процесса. Новый `WKWebView` получает его до attach; при отсутствии state загружается последний committed URL.
- Active, playing-media, camera/microphone capture, element-fullscreen и незавершённые native UI flows защищены. Перед pressure eviction playback state обновляется асинхронным запросом WebKit с коротким fail-safe для зависшего content process.
- Reconcile запускается событиями выбора/создания/закрытия, app/thermal/memory transitions и idle timer не чаще одного раза в 30 секунд.

## Последствия

Фоновая вкладка может reload-нуться, если WebKit не вернул пригодный interaction state. Playback protection намеренно консервативна: public API сообщает playing state, но не гарантирует audible-only классификацию. WebAuthn/payment protection и воспроизводимые Instruments pressure benchmarks остаются отдельной работой перед закрытием всех exit criteria Phase 4.
