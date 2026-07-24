# Changelog

## 0.1.4 — Link Previews

- Added Shift-click link previews backed by a live WebKit session, with promotion to a tab without reloading the page.
- Refined preview presentation for pinned and auto-hide sidebars with Liquid Glass controls and framing.
- Added a persistent sidebar hint explaining link previews.
- Updated the bundle version to `0.1.4` (`26`).

## 0.1.3 — Fullscreen Media Stability

- Preserved WebKit's fullscreen view hierarchy during SwiftUI host updates.
- Deferred web view reattachment until fullscreen transitions finish to prevent gray video frames and lost controls.
- Updated the bundle version to `0.1.3` (`25`).

## 0.1.2 — Sidebar and Clipboard Polish

- Added reliable page-address copying to the system clipboard with `⇧⌘C` and a confirmation toast.
- Refined the pinned sidebar into a full-height side region with rounded page-leading corners.
- Preserved the floating glass treatment for the auto-hide sidebar mode.
- Updated the bundle version to `0.1.2` (`24`).

## 0.1.1 — Public Beta

- Added isolated private windows (`⌘⇧N`) without persistent browsing data.
- Migrated session and browsing history to SwiftData with one-time JSON migration.
- Added live transfer of selected tabs to a new regular window without reloading them.
- Added automatic WebKit cache cleanup every seven days and removal of history older than 90 days.
- Added a production release pipeline with Developer ID signing, Hardened Runtime, secure timestamps, Apple notarization, ticket stapling, and Gatekeeper verification.
- Updated the bundle version to `0.1.1` (`23`).

Known limitation: native trackpad swipe is reliable within the current WebKit process history. At the edge of the logical history restored after a restart, Back/Forward buttons and `⌘[`/`⌘]` are guaranteed; swipe behavior may be less predictable.
