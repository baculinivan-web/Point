# Changelog

## 0.1.1 — Public Beta

- Added isolated private windows (`⌘⇧N`) without persistent browsing data.
- Migrated session and browsing history to SwiftData with one-time JSON migration.
- Added live transfer of selected tabs to a new regular window without reloading them.
- Added automatic WebKit cache cleanup every seven days and removal of history older than 90 days.
- Added a production release pipeline with Developer ID signing, Hardened Runtime, secure timestamps, Apple notarization, ticket stapling, and Gatekeeper verification.
- Updated the bundle version to `0.1.1` (`23`).

Known limitation: native trackpad swipe is reliable within the current WebKit process history. At the edge of the logical history restored after a restart, Back/Forward buttons and `⌘[`/`⌘]` are guaranteed; swipe behavior may be less predictable.
