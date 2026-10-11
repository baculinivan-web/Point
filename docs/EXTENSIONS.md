# WebExtensions in Point

Point uses the public WebKit WebExtension runtime on macOS 26. Compatibility depends on the APIs available in the installed WebKit version and the operations implemented by Point; this is not full Chrome or Firefox compatibility.

## Installing an extension

Open Settings → Extensions, paste a Chrome Web Store detail-page URL (or its 32-character extension ID), and choose **Install from Chrome Web Store**. **Open store** opens the catalog in Point. Opening extension settings while viewing a store detail page pre-fills its link. Point downloads the original CRX3 package from Google's update service, verifies its signatures and developer identity, extracts it with path/type/size checks, and asks you to review permissions before enabling it. Resource files and manifests are not modified. Duplicate store installations are rejected. Store extensions follow the same private-window and permission rules as folder installations. Point offers installation in a browser-owned banner on extension detail pages (including store History API navigation), not on catalog/category pages. Downloads, verification, installation, success and cancellation have visible status; failures show their error. The link field also submits with Return. Downloads require network access; unavailable/private store packages cannot be installed this way.

Folder installation remains available:

1. Obtain and unpack the extension so that `manifest.json` is at the root of a folder.
2. Open Settings → Extensions → Install from folder.
3. Select that folder and review the requested capabilities and websites.
4. Install, then reload existing pages.

Point copies the folder into its application support directory, so the source folder can be moved or deleted. Symbolic links and special files are rejected. Extensions can be disabled, removed, or have individual website/API grants revoked in Settings. “Grant requested access” restores the manifest's requested grants after confirmation. Optional permissions requested at runtime also require approval. Specific URL requests expire after one hour and are not persisted by Point.

Reload pages after disabling an extension or revoking access: scripts that already ran cannot be undone. Extensions are excluded from private windows, including private popups. Normal-window extensions cannot enumerate private tabs or create private windows.

## Included example

Install `Examples/Extensions/PointDemo`, grant its permissions, and visit `https://example.com`. A badge checks content injection, background messaging, local storage and tab enumeration. Open Point Demo from the puzzle-piece menu to check its popup; its settings page opens from Settings → Extensions.

## Implementation

- `BrowserExtensionStore` atomically saves installation metadata and grants in `Point/Extensions/extensions.json` under the app's application support directory. Each extension has an independent UUID and resource folder.
- `BrowserExtensionManager` owns one persistent `WKWebExtensionController` shared by regular windows. It restores contexts with stable identifiers and `webkit-extension` origins. WebKit manages background execution, storage and supported JavaScript APIs.
- `ExtensionWindowAdapter` and `ExtensionTabAdapter` expose regular windows and tabs, relay lifecycle/property events, and implement opening, activation, navigation, duplication, pinning, closing, window focus, frame and state. Sleeping tabs remain listed without being woken by metadata queries. Transfers to a new Point window retain the extension tab identity.
- `WebEngineSession` sets the controller before constructing a `WKWebView`. Extension pages use their context's `webViewConfiguration`; tabs replace their web view when entering or leaving an extension origin. Extension-resource navigation is allowed only when its origin belongs to a loaded context.
- The puzzle-piece menu shows current icons, titles and badge text. Extension popups use a movable, resizable native panel containing WebKit's popup view controller. The panel is attached above its browser window, so focusing the page does not cover it. Closing the panel, disabling the extension or closing its host window tears down the popup. Options pages use regular tabs. Extensions declaring `side_panel.default_path` or `sidebar_action.default_panel` can open that page in a trailing panel, via their action when it has no popup or via Settings. The panel uses the extension context configuration, closes on disable/removal/window closure, and is excluded from private windows. This hosts declared panel pages; it does not implement the Chrome `sidePanel` JavaScript API (dynamic panel options, programmatic opening and events).
- Private sessions never receive a controller, and contexts have `hasAccessToPrivateData` disabled.

Supported manifests are checked by WebKit; recoverable manifest warnings and context errors appear in Settings. Missing names, versions and unsupported manifest versions prevent installation. There are no automatic extension updates. Point warms background content before completing installation, waiting at most three seconds so a failed worker cannot leave installation stuck. Action popups wait for background listeners before opening, with a bounded timeout. A background startup failure leaves the extension installed and is reported in Settings.

## Current limits

On the tested macOS 26.2 system, manifest-declared CSS did not apply in the automated compatibility check, although content JavaScript, background messaging and local storage worked. This remains an open compatibility issue, recorded as a known issue in `manifestCSSCompatibility`. CSS-dependent extensions require individual verification; Point does not currently claim reliable manifest CSS injection. The included demo's badge may appear without its stylesheet.

Extension-owned pages and background workers use a Chromium compatibility user-agent token. Without a recognized browser token, Bitwarden 2026.9.3 throws while determining its device type; the Safari code path also assumes native-app integration unavailable in Point. This configuration affects only extension contexts; ordinary website tabs retain Point's Safari/WebKit identity. It does not add missing Chromium APIs or native messaging.

The original Vimium 2.4.2 package calls `webNavigation.onHistoryStateUpdated` and `onReferenceFragmentUpdated`, which the tested WebKit runtime does not expose. It also contains file-directory match patterns that WebKit rejects. Point installs the original package without applying compatibility patches. Successful installation is not a guarantee of complete functionality.

There is no installation from Firefox Add-ons, local archive/CRX import, native messaging, sync service, extension-provided new-tab override or extension context-menu integration. Popup-type window creation and moving existing tabs through `windows.create({tabId: ...})` return an unsupported-operation error. API compatibility for arbitrary third-party extensions must be verified individually. Point exposes window coordinates in AppKit's coordinate system.

## Validation

`swift test --filter BrowserExtensionTests` checks installation approval/cancellation, malformed resources, symlink rejection, stable restoration, disabling and re-enabling, persistent permission revocation, local HTTP content injection, background messages, storage, tabs, private-window isolation, extension-page navigation and movable popup lifecycle. The test extension only has host access to the loopback test server. No Chrome instance is used.

`ChromeWebStoreInstallerTests` checks store links, signed CRX3 identity and tampering, bounded ZIP extraction, unsafe paths and symlinks. No external archive utility or Chrome instance is needed. ZIP32 stored/deflate entries are supported, with limits of 128 MiB per downloaded package, 64 MiB per extracted file, 512 MiB total and 30,000 entries. Encrypted, multi-volume and ZIP64 archives are rejected.

Shift–Command–C copies the live web view URL, including History API/fragment changes. Same-document URL changes also update the tab address. The ChatGPT extension `hehggadaopoacecdllhhajmbjkdcmajg` additionally requests Chrome Debugger and native messaging; opening its declared panel does not supply these integrations or imply that the extension is functional. Point displays this limitation in Settings and the panel.
