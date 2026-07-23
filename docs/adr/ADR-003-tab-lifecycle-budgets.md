# ADR-003: Tab lifecycle and resident budgets

- Status: accepted
- Date: 2026-07-22

## Context

Metadata-only session restore reduces startup cost, but a long session can still retain one `WKWebView` for every tab the user has selected. Private WebKit APIs and constant memory polling are not acceptable.

## Decision

- The browser has a soft resident-memory budget that defaults to 50% of installed physical memory. Users can choose 25–90% in 5% increments in Settings, and the persisted setting applies to all windows. The measurement uses the process resource coalition's physical footprint, which includes Point and its launchd-hosted WebKit XPC services. A conservative 192 MB floor per resident web view is used only when coalition accounting is unavailable or lower and is shown as an estimate. Public WebKit APIs do not expose per-tab process memory. Background tabs remain live for at least ten idle minutes while the browser remains below that budget.
- When a sample exceeds the budget, one least-recently-used eligible tab is evicted. Memory is sampled again after WebKit has had time to release its process before another candidate is considered. Warning and serious thermal states suspend eligible background tabs; critical pressure keeps only active and explicitly protected tabs.
- LRU uses the last activation time. A new or just-visited tab receives a grace period.
- An eligible idle background tab is suspended with paired `setAllMediaPlaybackSuspended`; selecting it resumes media.
- Before eviction, opaque `interactionState` remains in process memory only. A new `WKWebView` receives it before attachment; without it, the last committed URL is loaded. No page image is persisted; the UI shows a neutral loading placeholder while an evicted tab is restored.
- Active tabs, playing media, camera/microphone capture, element fullscreen, and unfinished native UI flows are protected. Before pressure eviction, playback state is refreshed asynchronously with a short fail-safe for a stalled content process.
- Reconciliation is triggered by selection, creation, closure, app/thermal/memory transitions, and an idle timer no more often than once every 30 seconds.

## Consequences

A background tab may reload if WebKit does not return usable interaction state; public WebKit APIs cannot serialize and revive a terminated content process as a live page. The placeholder makes this transition explicit instead of displaying stale page imagery. Playback protection is intentionally conservative: the public API reports playing state but does not guarantee an audible-only classification. WebAuthn/payment protection and reproducible Instruments pressure benchmarks remain follow-up work before all Phase 4 exit criteria are closed.
