# Point — Technical Documentation

This document is the technical reference for Point 0.1.1. It covers the implemented product surface, architecture, persistence, lifecycle policy, security boundaries, testing, and release process. For product principles and user experience, see [PRODUCT_VISION.md](./PRODUCT_VISION.md).

## 1. Platform and stack

- macOS 26 or later
- Swift 6
- SwiftUI for the application UI
- WebKit, primarily `WKWebView`, for web content
- SwiftData for session and browsing-history metadata
- Xcode 26 or later

Point is a native macOS application. SwiftUI owns the window, sidebar, omnibox, menus, dialogs, downloads UI, permission prompts, start page, and error states. `WKWebView` is hosted in SwiftUI through a small `NSViewRepresentable` adapter. AppKit is used only where the required macOS window or WebKit hosting API is not currently exposed by SwiftUI.

The project is organized into these targets:

- `BrowserCore` — pure models, commands, lifecycle policy, and omnibox parsing.
- `BrowserEngine` — `WKWebView`, delegates, navigation, downloads, and the SwiftUI host.
- `BrowserPersistence` — atomic persistence for session, permissions, browsing history, and download history outside the main actor.
- `BrowserUI` — window model, sidebar, omnibox, and design system.
- `BrowserApp` — composition root and scenes.

The engine choice and live-tab model are recorded in [ADR-001](adr/ADR-001-web-engine.md). Lifecycle budgets are recorded in [ADR-003](adr/ADR-003-tab-lifecycle-budgets.md).

## 2. Implemented browser behavior

### Tabs, windows, and navigation

- Real web content is rendered through `WKWebView`.
- Ordinary tab switching keeps a live web view and does not reload the page.
- Multiple regular windows are supported.
- Selected tabs can move to a new regular window without a reload. The live web view, media state, and scroll state move with the tab.
- `target=_blank` and `window.open` create a new tab using the WebKit-provided configuration.
- Tabs can be created, closed, reopened, pinned, and reordered with drag and drop.
- Saved tab folders support unlimited nesting, SF Symbols icons, renaming, range selection with Shift, group moves, and recursive deletion.
- Back, Forward, Reload, Reload Without Cache, and Stop are available, including `⌘[` and `⌘]` for Back/Forward.
- The current process uses the native two-finger horizontal gesture for its WebKit back-forward list.
- Find in Page is supported.
- File inputs and JavaScript alert, confirm, and text-prompt dialogs are handled natively.

### Sidebar and omnibox

The sidebar has three modes:

1. **Pinned** — visible with a reserved viewport.
2. **Hidden** — absent until explicitly shown.
3. **Overlay** — a temporary Liquid Glass surface that does not resize the page.

The omnibox classifies input safely as a URL or a search query. Open tabs can be searched locally. The sidebar and omnibox expose system shortcuts and accessibility labels.

### Session restore and history navigation

Point restores tab URL, title, order, sidebar mode, and the logical back-forward stack. Up to 50 committed transitions are persisted per tab.

Restored history is action-driven: Back/Forward and `⌘[`/`⌘]` load an older page only after the user asks for it. Point does not replay old network requests in the background. The native trackpad gesture is reliable inside the current WebKit process; at a persisted history boundary after restart, the buttons and keyboard commands are the guaranteed path.

## 3. Web content lifecycle and memory

### States

Tabs move through these lifecycle states:

`active` → `liveBackground` → `suspended` → `evicted` → `restoring`

`crashed` is a recovery state for a terminated Web Content process.

`active` is the selected tab and is attached to the SwiftUI hierarchy. `liveBackground` retains a live web view without being visible. `suspended` keeps the runtime but pauses media. `evicted` keeps metadata and, where available, opaque in-process `WKWebView.interactionState`; it releases the web view. `restoring` creates a new web view, shows a neutral loading placeholder, and restores interaction state or falls back to the last committed URL.

The policy uses an LRU order and a configurable browser-process memory budget. The default is 50% of installed physical memory:

| Physical memory | Browser memory budget |
|---|---:|
| 8 GB | 4 GB |
| 16 GB | 8 GB |
| 32 GB | 16 GB |
| 64 GB | 32 GB |

The memory setting accepts 25–90% in 5% increments and applies to all windows through `UserDefaults`; a running window reads the new value on its next sample. The app samples its resource-coalition physical footprint every three seconds. macOS assigns the Point UI process and its launchd-hosted WebKit XPC services to the same resource coalition, so this aggregate includes Web Content, Networking, and GPU memory without guessing their parent PIDs. Point applies a conservative floor of 192 MB per resident web view only if coalition accounting is unavailable or lower; the sidebar marks that fallback with `≈`. The same effective value drives the lifecycle budget. When it exceeds the budget, Point evicts one eligible LRU tab and waits for the next sample before considering another. Public WebKit APIs do not expose exact per-tab process memory. Reconciliation also runs after tab selection, creation, or closure and after app, thermal, and memory-pressure transitions.

Eviction protections include the active tab, playing media, camera or microphone capture, element fullscreen, and unfinished native dialog or file flows. Media suspension and resume are paired. Playback protection is conservative: any WebKit `.playing` state is treated as protected because there is no reliable public audible-only API.

The opaque interaction state is intentionally process-local and is never written to disk. After a restart, only the safe logical URL/title history is restored. This preserves user-controlled Back/Forward without archiving form or scroll state or issuing old requests automatically.

## 4. Persistence and data ownership

SwiftData stores session and browsing-history models. A one-time migration converts legacy `session.json` and `history.json` files into `.migrated` files.

The normal persistent WebKit data store owns cookies, local storage, IndexedDB/WebSQL, service workers, and WebKit cache. Each private window receives its own `WKWebsiteDataStore.nonPersistent()` session.

Additional stores are deliberately separate:

- `downloads.json` — the last 200 completed, cancelled, or failed downloads.
- `permissions.json` — persistent camera and microphone decisions.
- `Caches/Browser/Favicons` — recreatable origin-keyed favicon cache.

Private session, history, permissions, download list, and favicon cache are memory-only. Closing the last private window releases its runtime and does not restore private metadata after relaunch. Explicitly downloaded files remain on disk.

Browsing history is written after a main-frame commit, then receives its final title after navigation finishes. Fast duplicates are merged and the history is capped at 5,000 entries. History rows use the origin-keyed favicon cache only in cache-only mode, so opening the history window does not create network requests.

## 5. Site permissions and native web flows

### Camera and microphone

Permission requests are serialized across the app. A request from a background tab waits for that tab to become the selected context. Navigation and closure safely cancel stale handlers. The Point prompt presents three choices: allow once, always allow, or deny.

Persistent decisions are keyed by normalized origin and resource type in an atomic JSON store. Persistent allow is available only for HTTPS. Top-level and subframe origins are displayed separately.

The application menu includes a site-permissions manager with allow/deny entries, individual revocation, and clear-all. Revoking an active allow stops the current WebKit capture for that origin.

The local manual fixture intentionally permits only one-time access over HTTP. Persistent allow is tested only over HTTPS.

### Other dialogs and authentication

- HTTP Basic and Digest authentication use a native credential prompt and never persist passwords.
- External `mailto`, `tel`, and `facetime` links require confirmation.
- Unknown external schemes are blocked.
- Passkeys use the system WebKit WebAuthn flow backed by Keychain or compatible credential providers. Point requests access before creating the first page and offers a later re-check in the application menu.

## 6. Downloads

Downloads are managed at application scope through one `DownloadManager` shared by all windows. Ordinary, attachment, and unsupported-MIME downloads are handed to `WKDownload`.

The implementation provides:

- automatic saving to the system Downloads folder;
- safe filename normalization and collision suffixes;
- progress, cancellation, resume, and persisted resume data;
- a compact Liquid Glass progress bubble in the upper-left corner;
- hover-to-hide for the bubble without cancelling the download;
- a downloads view in the sidebar, opened from the toolbar or with `⌘⇧J`;
- clearing the list and revealing completed files in Finder;
- atomic persistence of the last 200 completed, cancelled, or failed entries.

Download history intentionally excludes source URLs, query strings, and resume data from its durable list. A download continues after its originating tab is closed or transferred. On quit, Point asks for confirmation when downloads are active; a confirmed quit flushes queued download-history writes first. Clearing browsing data does not cancel active downloads.

## 7. Browsing-data clearing and maintenance

The Clear Browsing Data command (`⌘⇧⌫`) independently clears:

- browsing history;
- cookies;
- WebKit cache;
- local storage, IndexedDB, and WebSQL;
- service workers;
- site permissions;
- download history;
- favicon cache.

Active downloads are preserved. Live tabs reload after their WebKit data is removed. Manual clearing currently uses the exact all-time period. Automatic maintenance runs every seven days and removes WebKit cache plus history entries older than 90 days. Arbitrary user-selected date ranges remain future work.

## 8. macOS integration and visual system

Point registers `http` and `https` handling, accepts external URLs, and exposes an explicit command to set itself as the default browser.

The UI uses native Liquid Glass surfaces for the sidebar, omnibox, temporary panels, download indicators, and permission prompts. Reduce Transparency and Reduce Motion settings have native fallbacks. Glass is limited to appropriate surfaces; tab rows do not receive unnecessary glass layers. Accessibility labels, keyboard commands, focus order, and keyboard-only paths are part of the implementation.

## 9. Build, manual fixtures, and release

Run the local test suite and app with:

```bash
make test
make run
```

`make run` builds a locally signed app bundle at `dist/Point.app`. The package can also be opened in Xcode through `Package.swift`.

For a production release, store a `notarytool` profile and run:

```bash
xcrun notarytool store-credentials point-notary
NOTARY_PROFILE=point-notary make release
```

The release pipeline builds the Release configuration, enables Hardened Runtime and a secure timestamp, validates the signature, submits the zip to Apple, staples the ticket, and runs final `stapler` and Gatekeeper checks. It exits before publication if a Developer ID Application identity or notary profile is missing.

The local fixture server exercises downloads, camera and microphone permissions, JavaScript prompts, HTTP Basic authentication (`browser` / `test`), and `mailto` confirmation without relying on public websites:

```bash
python3 scripts/manual-test-server.py
```

Open `http://localhost:8765` in Point. The slow download fixture exposes the progress bubble and active-download quit warning. The camera fixture shows the Point permission prompt, the macOS system request, and a preview. The local HTTP fixture allows only one-time permission; persistent allow is intentionally HTTPS-only.

## 10. Testing and quality gates

Unit coverage includes omnibox URL/search classification, invalid schemes and IDN handling, tab ordering, lifecycle transitions, protected reasons, adaptive budgets, command enablement, history deduplication, origin permission lookup, safe download filenames, session migration, and sidebar state transitions.

The local integration suite covers redirects, slow pages, Basic auth, file upload, ordinary and blob downloads, `Content-Disposition` filenames, `target=_blank`, `window.open`, JavaScript dialogs, camera/microphone permission paths, fullscreen media, service workers, local storage, and process recovery where public APIs allow it.

UI and manual checks cover launch and restore, new/select/close/reopen tab flows, pinned and auto-hide sidebars, hover reveal, keyboard-only use, cross-window tab transfer, omnibox result selection, permission queues, download destinations, private-window isolation, fullscreen, Reduce Motion, and Reduce Transparency.

Performance checks use Instruments signposts for launch, tab switching, eviction and restoration. The lifecycle policy has unit coverage; eviction and restore are signposted. The 100-cycle memory exit criteria and pressure benchmarks still require a manual Instruments run on real M1 8 GB hardware and are not yet claimed as passed.

## 11. Current beta scope and known limitations

The public-beta scope includes private windows, SwiftData migration, live tab transfer between regular windows, periodic cleanup, production signing and notarization, downloads, native web dialogs and authentication, the camera/microphone permission queue, browsing history, and Clear Browsing Data.

Remaining local integration checks include OAuth popups, blob downloads, fullscreen, and TLS flows. WebAuthn and payment flows do not yet have separate protected lifecycle reasons. Persistent trackpad-swipe behavior at a restored-history boundary may be less predictable than the Back/Forward buttons and keyboard shortcuts.

Private browsing is not anonymity from websites, networks, employers, or internet providers. It isolates local browser data and releases the private runtime after closure; files explicitly downloaded by the user remain on disk.

## 12. Further implementation plan

The implementation plan is summarized in [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md). Architectural decisions should be recorded as short ADRs in `docs/adr/`, with context, decision, alternatives, and consequences rather than a code dump.
