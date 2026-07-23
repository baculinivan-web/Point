# ADR-001: `WKWebView` as the MVP web engine

- Status: accepted
- Date: 2026-07-22

## Context

Point needs tabs, popup navigation, complete navigation policy, recovery after a Web Content process termination, and precise web-view lifecycle control. These requirements matter more than the shorter implementation of a SwiftUI-only prototype.

## Decision

Use one `WKWebView` per live tab and a minimal `NSViewRepresentable` host. SwiftUI attaches only the active web view to the view hierarchy. Restored tabs remain metadata-only until the user selects them.

## Consequences

- Delegate and KVO integration is contained in `BrowserEngine`.
- Popups are created with the configuration supplied by WebKit.
- A background tab does not have to consume web-view memory immediately after session restore.
- Downloads, the permission queue, and `interactionState`-based eviction can be added without replacing the host architecture.
