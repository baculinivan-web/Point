# Point

Point is a native browser for macOS 26 and later, built with SwiftUI and WebKit. Version 0.3.7 is a public beta; web compatibility and performance testing are ongoing.

[Website](https://baculinivan-web.github.io/point-browser-landing/) · [Download the latest release](https://github.com/baculinivan-web/Point/releases/latest)

## Features

- Sidebar tabs with pinned pages, nested folders, tab search, and session restoration.
- Address suggestions from open tabs, browsing history, recent searches, and a bundled site list.
- Split view, link previews, downloads, and site permission controls.
- Private windows with separate browsing data. Downloaded files remain on your Mac.
- Native Mac shortcuts, trackpad gestures, and accessibility support.
- Built-in ad blocking and WebExtensions support.

## Ad blocking and extensions

Ad blocking is enabled by default in regular and private tabs. To change it, open Settings → General → Ad blocking and reload your pages. Bundled AdGuard Base and Russian filters block requests and hide banners. Filters do not update automatically, and video ads or ads requiring scriptlet rules may remain. Filter sources, licenses, and update instructions are in [`Sources/BrowserEngine/Resources/AdBlock`](Sources/BrowserEngine/Resources/AdBlock).

Install extensions from a Chrome Web Store link or a local folder in Settings → Extensions. Review their permissions before installing. Compatibility depends on WebKit support, and extensions are disabled in private windows. See the [extensions guide](docs/EXTENSIONS.md).

## Build and test

```bash
make test
make run
```

`make run` builds and opens `dist/Point.app`. You can also open `Package.swift` in Xcode. Use `make release` to create `dist/Point.dmg`.

See the [technical documentation](docs/TECHNICAL_DOCUMENTATION.md) for setup, architecture, testing, release requirements, and known limitations, or the [product vision](docs/PRODUCT_VISION.md) for design principles.
