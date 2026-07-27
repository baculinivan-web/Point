# Changelog

## 0.2.0 — Chat

- Added a built-in chat that opens beside the page (`⇧⌘A` or the sparkle button in the sidebar), can be hidden, resized by dragging its edge, or detached into its own window.
- Supported providers: Anthropic (Claude), any OpenAI-compatible server, and local models through Ollama — with in-app Ollama detection, one-click install, and model download.
- The chat receives the current page as context by default (toggleable in Settings), searches the web through the browser, reads pages, and opens tabs; chat-opened tabs carry a sparkle badge in the sidebar.
- Added image and file attachments: images go to multimodal models directly, while PDFs and text files are extracted to text so they work on every provider. The attach control reflects whether the selected model can read images.
- Answers render Markdown blocks natively, including tables, lists, headings, quotes, and code.
- Past chats are stored on disk and reachable from the chat menu; links in a reply open in a browser tab.
- Added a context meter that warns as the conversation fills the model's window, with manual and automatic compaction that summarizes older turns and keeps recent ones.
- Added memory that persists across chats: the model can remember, recall, search, and forget notes, and recent memories are carried into every conversation. Clearable from Settings.
- Added tools for capturing a page screenshot, running Python in the app sandbox, listing open tabs, and filing tabs into a named folder.
- The panel is tinted Liquid Glass with a floating composer that the transcript scrolls beneath.
- API keys are stored in the keychain; responses stream live with visible tool activity.
- Added a chat setup step to the welcome tour and a Chat section in Settings.
- Updated the bundle version to `0.2.0` (`28`).

## 0.1.5 — Split View and Default Browser

- Added two-pane split workspaces: drag a sidebar tab onto either half of the page to pair it with the active tab.
- Added a draggable divider that resizes the panes and persists the ratio across launches.
- Both panes stay live and protected from suspension and eviction while the split is on screen.
- Added Point selection as the default browser from Settings, with `http` and `https` handling declared at default rank.
- Updated the bundle version to `0.1.5` (`27`).

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
