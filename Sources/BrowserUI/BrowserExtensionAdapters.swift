import AppKit
import BrowserCore
import WebKit

@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var model: BrowserWindowModel?
    unowned let manager: BrowserExtensionManager
    private(set) var adapters: [ExtensionTabAdapter] = []
    private var activeID: TabID?
    private var selection: Set<TabID> = []
    var activeAdapter: ExtensionTabAdapter? { adapters.first { $0.id == model?.selectedTabID } }

    init(model: BrowserWindowModel, manager: BrowserExtensionManager) {
        self.model = model
        self.manager = manager
    }

    func sync() {
        guard let model else { return }
        let tabs = model.tabs.sorted { lhs, rhs in
            if lhs.spaceID != rhs.spaceID {
                return (model.spaces.firstIndex { $0.id == lhs.spaceID } ?? 0)
                    < (model.spaces.firstIndex { $0.id == rhs.spaceID } ?? 0)
            }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.position < rhs.position
        }
        let previous = adapters
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        var moved: [TabID: (ExtensionWindowAdapter, Int)] = [:]
        adapters = tabs.map { tab in
            if let existing = oldByID[tab.id] { return existing }
            if let (transferred, oldWindow, index) = manager.takeTransferred(tab.id, into: self) {
                moved[tab.id] = (oldWindow, index)
                return transferred
            }
            return ExtensionTabAdapter(tab: tab, owner: self)
        }
        for tab in previous where !adapters.contains(where: { $0 === tab }) {
            if !manager.isTransferring(tab.id) { manager.controller.didCloseTab(tab) }
        }
        for (index, tab) in adapters.enumerated() {
            if let oldIndex = previous.firstIndex(where: { $0 === tab }) {
                if oldIndex != index { manager.controller.didMoveTab(tab, from: oldIndex, in: self) }
                tab.syncChanges()
            } else if let (oldWindow, oldIndex) = moved[tab.id] {
                manager.controller.didMoveTab(tab, from: oldIndex, in: oldWindow)
            } else { manager.controller.didOpenTab(tab) }
        }
        if let active = activeAdapter, activeID != active.id {
            manager.controller.didActivateTab(active, previousActiveTab: oldByID[activeID ?? active.id])
        }
        activeID = model.selectedTabID
        let selected = model.selectedTabIDs
        manager.controller.didDeselectTabs(previous.filter { selection.contains($0.id) && !selected.contains($0.id) })
        manager.controller.didSelectTabs(adapters.filter { selected.contains($0.id) && !selection.contains($0.id) })
        selection = selected
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { adapters }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeAdapter }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = model?.extensionHostWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }
    func frame(for context: WKWebExtensionContext) -> CGRect { model?.extensionHostWindow?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { model?.extensionHostWindow?.screen?.frame ?? .zero }
    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = model?.extensionHostWindow else { completionHandler(CocoaError(.featureUnsupported)); return }
        window.setFrame(frame, display: true)
        completionHandler(nil)
    }
    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = model?.extensionHostWindow else { completionHandler(CocoaError(.featureUnsupported)); return }
        let fullscreen = window.styleMask.contains(.fullScreen)
        if (state == .fullscreen) != fullscreen { window.toggleFullScreen(nil) }
        if state == .minimized { window.miniaturize(nil) }
        else if window.isMiniaturized { window.deminiaturize(nil) }
        if state != .fullscreen && state != .minimized && (state == .maximized) != window.isZoomed { window.zoom(nil) }
        completionHandler(nil)
    }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = model?.extensionHostWindow else { completionHandler(CocoaError(.featureUnsupported)); return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = model?.extensionHostWindow else { completionHandler(CocoaError(.featureUnsupported)); return }
        window.performClose(nil)
        completionHandler(nil)
    }
}

@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    let id: TabID
    weak var tab: BrowserTab?
    weak var owner: ExtensionWindowAdapter?
    private var lastURL: URL?
    private var lastTitle: String
    private var lastLoading: Bool
    private var lastPinned: Bool
    private weak var lastWebView: WKWebView?

    init(tab: BrowserTab, owner: ExtensionWindowAdapter) {
        id = tab.id
        self.tab = tab
        self.owner = owner
        lastURL = tab.url
        lastTitle = tab.title
        lastLoading = tab.isLoading
        lastPinned = tab.isPinned
        lastWebView = tab.engine?.webView
    }
    func syncChanges() {
        guard let tab, let owner else { return }
        var changes: WKWebExtension.TabChangedProperties = []
        let url = tab.engine?.webView.url ?? tab.url
        if lastURL != url { changes.insert(.URL) }
        if lastTitle != tab.title { changes.insert(.title) }
        if lastLoading != tab.isLoading { changes.insert(.loading) }
        if lastPinned != tab.isPinned { changes.insert(.pinned) }
        if lastWebView !== tab.engine?.webView { changes.formUnion([.URL, .loading]) }
        lastURL = url
        lastTitle = tab.title
        lastLoading = tab.isLoading
        lastPinned = tab.isPinned
        lastWebView = tab.engine?.webView
        if !changes.isEmpty { owner.manager.controller.didChangeTabProperties(changes, for: self) }
    }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        // Querying tab metadata must not wake every sleeping tab.
        tab?.engine?.webView
    }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.engine?.webView.url ?? tab?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? false) }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.isPinned ?? false }
    func isSelected(for context: WKWebExtensionContext) -> Bool { owner?.model?.selectedTabIDs.contains(id) ?? false }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { owner?.model?.isPrivate == false }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let model = owner?.model else { completionHandler(CocoaError(.featureUnsupported)); return }
        model.selectTab(id)
        model.extensionHostWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let model = owner?.model else { completionHandler(CocoaError(.featureUnsupported)); return }
        model.setPinned(pinned, for: id)
        completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let model = owner?.model else { completionHandler(CocoaError(.featureUnsupported)); return }
        model.navigate(tabID: id, to: .url(url))
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let model = owner?.model else { completionHandler(CocoaError(.featureUnsupported)); return }
        model.closeTab(id)
        completionHandler(nil)
    }
    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let owner, let model = owner.model else { completionHandler(nil, CocoaError(.featureUnsupported)); return }
        let duplicate = model.openAssistantTab(url: configuration.url ?? tab?.url ?? URL(string: "about:blank")!, inBackground: !configuration.shouldBeActive, isAICreated: false)
        model.setPinned(configuration.shouldBePinned, for: duplicate.id)
        owner.sync()
        completionHandler(owner.adapters.first { $0.id == duplicate.id }, nil)
    }
}
