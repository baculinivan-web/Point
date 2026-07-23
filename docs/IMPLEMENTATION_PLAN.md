# Point — Implementation Plan

This is the English implementation roadmap for Point. The current system behavior and technical constraints are documented in [TECHNICAL_DOCUMENTATION.md](./TECHNICAL_DOCUMENTATION.md).

## Scope and priorities

The first release prioritizes a reliable browser vertical slice, a sidebar that does not fight the page, predictable tab lifecycle, privacy-safe persistence, and native macOS behavior. Features are evaluated against their cost in memory, energy, interaction complexity, and stability.

### P0 — public beta

- Native web browsing through `WKWebView`.
- URL/search omnibox and familiar navigation commands.
- Tabs, pinned tabs, nested folders, reorder, close/reopen, and session restore.
- Multiple windows and live tab transfer.
- Auto-hide, pinned, and overlay sidebar modes.
- Lifecycle budgets, media protection, eviction, and restoration.
- Browsing history, favicons, downloads, site permissions, native dialogs, and external-link confirmation.
- Private windows with isolated non-persistent WebKit stores.
- SwiftData migration and privacy-safe persistence.
- Liquid Glass with accessibility and Reduce Transparency/Reduce Motion fallbacks.
- Tests, diagnostics, signing, notarization, and a reproducible release build.

### P1 — after beta stability

- Broader web compatibility hardening.
- More diagnostics and opt-in crash reporting.
- Additional workspace or spaces behavior if it strengthens the core sidebar model.
- Expanded date-range controls for browsing-data clearing.
- Separate lifecycle protection for WebAuthn and payment flows.

## Phases

### Phase 0 — platform spikes and baseline

Confirm macOS 26 and Liquid Glass behavior on target hardware. Compare the required WebKit capabilities, validate the `WKWebView` host, build the local fixture server, and measure launch, blank-memory, five-tab-memory, and sidebar-animation baselines.

Exit when the engine decision is recorded, P0 WebKit capabilities work or have documented workarounds, benchmarks are repeatable, and platform blockers are known.

### Phase 1 — foundation

Set up package targets, dependency composition, the app and window models, command dispatch, SwiftData schema v1, repositories, OSLog categories, signposts, CI builds, and unit tests.

Exit when the app opens a window, persists and restores a metadata-only session, and builds with no new warnings or concurrency errors.

### Phase 2 — browser vertical slice

Implement the web-engine session and host, navigation delegates, one-tab browsing, URL/search input, Back/Forward, Reload, Stop, loading and error states, a start page, and basic menu/keyboard commands.

Exit when one tab supports a full working day, navigation state is reflected correctly, content-process recovery works, and the initial compatibility matrix loads.

### Phase 3 — sidebar-first tabs

Add tab stores, multiple tabs, active/background states, sidebar state machines, hover and grace behavior, reorder, pin, close/reopen, keyboard navigation, favicon cache, session restore, multiple windows, and live tab transfer.

Exit when auto-hide does not resize the page, 500 metadata rows scroll without a hitch, resident tab switching does not reload, and keyboard-only operation covers the core flow.

### Phase 4 — lifecycle and performance

Add interaction-state capture and restoration, adaptive resident budgets, memory-pressure monitoring, media suspend/resume, protected reasons, Instruments passes, performance scenarios, and retain-cycle cleanup.

Exit when repeated create/load/close cycles do not show linear memory growth, pressure produces expected eviction, protected tabs are preserved, and evicted tabs restore or safely reload.

### Phase 5 — browser completeness

Finish popup and new-window flows, downloads and resume, file input, JavaScript dialogs, HTTP authentication, camera/microphone permissions, Find in Page, fullscreen media, external schemes, default-browser handling, basic history UI, and Clear Browsing Data.

Exit when the local integration suite covers each flow, active downloads survive tab changes, origins are displayed correctly, and invalid TLS is never silently bypassed.

### Phase 6 — visual and interaction polish

Finalize design tokens, Liquid Glass surface topology, state transitions, accessibility labels and focus order, light/dark behavior, noisy-background readability, and 60/120 Hz tuning.

Exit when there are no unnecessary nested glass effects, accessibility checks pass, and the visual system stays within its performance budget.

### Phase 7 — private mode and hardening

Run private-data isolation tests, permission/history/cache leak tests, threat-model review, malformed URL and download tests, persistence-corruption recovery, migration fixtures, diagnostics export, and App Sandbox entitlement review.

Exit when private data cannot appear after restart, the last private window releases its runtime, the security checklist is closed, and corrupted session data cannot prevent launch.

### Phase 8 — beta stabilization

Dogfood on M1 8 GB hardware, run the compatibility matrix, triage crashes and hangs, repeat Instruments regressions, test clean install and update, package TestFlight or Developer ID builds, and document release notes and known limitations.

Exit when no known P0 data-loss, security, or crash bugs remain; memory is not monotonic in an eight-hour session benchmark; and Point works for core daily scenarios as the default browser.

## Definition of done

A feature is complete when it has product behavior plus empty/loading/error/disabled states, keyboard and accessibility paths, no synchronous I/O on the main actor, unit and integration coverage for failure cases, privacy-safe logs where needed, ordinary and private-window checks where applicable, Reduce Motion/Transparency checks for visual UI, a memory/performance smoke test, and updated documentation or an ADR for architectural changes.
