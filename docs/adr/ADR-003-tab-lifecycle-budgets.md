# ADR-003: Tab lifecycle and resident budgets

- Status: accepted
- Date: 2026-07-22

## Context

Metadata-only session restore reduces startup cost, but a long session can still retain one `WKWebView` for every tab the user has selected. Private WebKit APIs and constant memory polling are not acceptable.

## Decision

- The resident budget includes active and background live/suspended tabs: 2 for 8 GB, 4 for 16 GB, 7 for 24–32 GB, and 10 above 32 GB.
- Warning, inactive-app, and serious thermal states reduce the budget; critical pressure keeps only the active and explicitly protected tabs.
- LRU uses the last activation time. A new or just-visited tab receives a grace period.
- An eligible idle background tab is suspended with paired `setAllMediaPlaybackSuspended`; selecting it resumes media.
- Before eviction, opaque `interactionState` remains in process memory only. A new `WKWebView` receives it before attachment; without it, the last committed URL is loaded.
- Active tabs, playing media, camera/microphone capture, element fullscreen, and unfinished native UI flows are protected. Before pressure eviction, playback state is refreshed asynchronously with a short fail-safe for a stalled content process.
- Reconciliation is triggered by selection, creation, closure, app/thermal/memory transitions, and an idle timer no more often than once every 30 seconds.

## Consequences

A background tab may reload if WebKit does not return usable interaction state. Playback protection is intentionally conservative: the public API reports playing state but does not guarantee an audible-only classification. WebAuthn/payment protection and reproducible Instruments pressure benchmarks remain follow-up work before all Phase 4 exit criteria are closed.
