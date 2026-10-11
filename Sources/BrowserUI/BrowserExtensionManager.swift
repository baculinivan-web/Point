import AppKit
import BrowserCore
import Observation
import WebKit

@MainActor
@Observable
final class BrowserExtensionManager: NSObject, WKWebExtensionControllerDelegate, NSWindowDelegate {
    static let shared = BrowserExtensionManager()
    // Retain the template's WebKit process resources for the app lifetime. Destroying
    // the last configuration while background views close can trap in WebKit on macOS 26.2.
    private static let runtimeConfigurationTemplate = WKWebViewConfiguration()
    let controller: WKWebExtensionController
    private(set) var installed: [InstalledBrowserExtension] = []
    private(set) var errors: [UUID: String] = [:]
    private(set) var isBusy = false
    private(set) var canModify = true
    enum StoreInstallationStage: String {
        case downloading = "extensions_store_downloading"
        case verifying = "extensions_store_verifying"
        case installing = "extensions_store_installing"
        case installed = "extensions_store_installed"
        case cancelled = "extensions_store_cancelled"
    }
    private(set) var storeInstallationStage: StoreInstallationStage?
    private(set) var storeInstallationID: String?
    var errorMessage: String?
    private(set) var actionRevision = 0
    @ObservationIgnored private let store: BrowserExtensionStore
    @ObservationIgnored private var contexts: [UUID: WKWebExtensionContext] = [:]
    @ObservationIgnored private var transferring: [TabID: (ExtensionTabAdapter, ExtensionWindowAdapter, Int)] = [:]
    @ObservationIgnored private var windows: [ExtensionWindowAdapter] = []
    @ObservationIgnored private var sidePanelOwners: [WeakSidePanelOwner] = []
    private final class WeakSidePanelOwner {
        weak var model: BrowserWindowModel?
        init(_ model: BrowserWindowModel) { self.model = model }
    }
    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored private var activePopup: WKWebExtension.Action?
    @ObservationIgnored private(set) var popupPanel: NSPanel?
    @ObservationIgnored private var popupSizeObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingActionID: UUID?
    @ObservationIgnored private weak var popupWindow: ExtensionWindowAdapter?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingWindows: [UUID: (WKWebExtension.WindowConfiguration, WKWebExtensionContext, ((any WKWebExtensionWindow)?, (any Error)?) -> Void)] = [:]
    @ObservationIgnored private let approvalHandler: ((String, [String], Bool) -> Bool)?

    init(root: URL? = nil, controller: WKWebExtensionController? = nil, approvalHandler: ((String, [String], Bool) -> Bool)? = nil) {
        self.approvalHandler = approvalHandler
        store = BrowserExtensionStore(root: root ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Point/Extensions", isDirectory: true))
        self.controller = controller ?? Self.makeController()
        super.init()
        self.controller.delegate = self
        observers.append(NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.actionRevision += 1 }
        })
        for name in [WKWebExtensionContext.grantedPermissionsWereRemovedNotification, WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let context = notification.object as? WKWebExtensionContext else { return }
                Task { @MainActor [weak self] in self?.reconcileStoredGrants(for: context) }
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.controller.didFocusWindow(self.focusedWindow)
                }
            })
        }
    }

    static func makeController(configuration: WKWebExtensionController.Configuration = .default()) -> WKWebExtensionController {
        let webViewConfiguration = runtimeConfigurationTemplate.copy() as! WKWebViewConfiguration
        webViewConfiguration.userContentController = WKUserContentController()
        webViewConfiguration.websiteDataStore = configuration.defaultWebsiteDataStore
        // Chrome packages use this token to select their WebExtensions code path. A bare
        // WKWebView UA is unrecognized by Bitwarden; a Safari token selects native-app APIs.
        // This applies only to extension-owned pages/workers, never ordinary browsing tabs.
        webViewConfiguration.applicationNameForUserAgent = "Point/1.0 Chrome/134.0.0.0 Safari/605.1.15"
        configuration.webViewConfiguration = webViewConfiguration
        return WKWebExtensionController(configuration: configuration)
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        isBusy = true
        defer { isBusy = false }
        do {
            installed = try store.read()
            for record in installed where record.isEnabled {
                do { try await load(record) }
                catch { errors[record.id] = error.localizedDescription }
            }
        } catch { canModify = false; errorMessage = error.localizedDescription }
    }

    func chooseAndInstall() {
        guard !isBusy, canModify else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = text("extensions_choose_folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await install(from: url) }
    }

    func install(from source: URL) async {
        guard !isBusy, canModify else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        storeInstallationStage = nil
        storeInstallationID = nil
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        await installResources(from: source)
    }

    func installFromWebStore(_ input: String,
                             download: @Sendable (String) async throws -> Data = {
                                 try await ChromeWebStoreInstaller().download(id: $0)
                             }) async {
        guard !isBusy, canModify else { return }
        isBusy = true
        errorMessage = nil
        storeInstallationStage = nil
        storeInstallationID = nil
        defer { isBusy = false }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let storeID = try ChromeWebStoreInstaller.extensionID(from: input)
            storeInstallationID = storeID
            guard !installed.contains(where: { $0.chromeWebStoreID == storeID }) else {
                throw ChromeWebStoreInstaller.Failure.alreadyInstalled
            }
            storeInstallationStage = .downloading
            let package = try await download(storeID)
            storeInstallationStage = .verifying
            let resources = temporary.appendingPathComponent("resources", isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                let archive = try ChromeWebStoreInstaller.verifiedArchive(package, expectedID: storeID)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                try ChromeWebStoreInstaller.extract(archive, to: resources)
            }.value
            storeInstallationStage = .installing
            await installResources(from: resources, chromeWebStoreID: storeID)
            if errorMessage != nil { storeInstallationStage = nil }
            else { storeInstallationStage = installed.contains(where: { $0.chromeWebStoreID == storeID }) ? .installed : .cancelled }
        } catch { storeInstallationStage = nil; errorMessage = error.localizedDescription }
    }

    private func installResources(from source: URL, chromeWebStoreID: String? = nil) async {
        let id = UUID()
        do {
            try store.copyResources(from: source, id: id)
            let webExtension = try await WKWebExtension(resourceBaseURL: store.resources(for: id))
            try validate(webExtension)
            let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
            let sites = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
            let name = webExtension.displayName ?? source.lastPathComponent
            guard approve(name: name, requests: permissions + sites, installing: true) else {
                try FileManager.default.removeItem(at: store.resources(for: id))
                return
            }
            let record = InstalledBrowserExtension(id: id, name: name,
                version: webExtension.displayVersion ?? webExtension.version ?? "",
                isEnabled: true, permissions: permissions, sites: sites, chromeWebStoreID: chromeWebStoreID)
            try await load(record, webExtension: webExtension)
            do { try store.write(installed + [record]) }
            catch {
                if let context = contexts.removeValue(forKey: id) { try? controller.unload(context) }
                throw error
            }
            installed.append(record)
        } catch {
            try? FileManager.default.removeItem(at: store.resources(for: id))
            errorMessage = error.localizedDescription
        }
    }

    private func validate(_ webExtension: WKWebExtension) throws {
        guard webExtension.displayName?.isEmpty == false, webExtension.version?.isEmpty == false,
              webExtension.supportsManifestVersion(webExtension.manifestVersion) else {
            throw webExtension.errors.first ?? CocoaError(.fileReadCorruptFile) as Error
        }
    }

    private func load(_ record: InstalledBrowserExtension) async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: store.resources(for: record.id))
        try validate(webExtension)
        try await load(record, webExtension: webExtension)
    }

    private func load(_ record: InstalledBrowserExtension, webExtension: WKWebExtension) async throws {
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id.uuidString
        context.baseURL = URL(string: "webkit-extension://\(record.id.uuidString.lowercased())/")!
        context.hasAccessToPrivateData = false
        context.isInspectable = _isDebugAssertConfiguration()
        context.unsupportedAPIs = ["browser.runtime.connectNative", "browser.runtime.sendNativeMessage"]
        applyGrants(record, to: context)
        try controller.load(context)
        contexts[record.id] = context
        // Warm up listeners before newly opened pages send their first content messages.
        // Bound the wait: WebKit may never complete a failed worker startup. Runtime
        // failure must not roll back an otherwise valid installation.
        await warmBackground(of: context)
        errors[record.id] = nil
        for window in windows {
            guard let model = window.model else { continue }
            for tab in model.tabs {
                guard let url = tab.url, let engine = tab.engine,
                      controller.extensionContext(for: url) === context else { continue }
                _ = model.webEngine(engine, requestsConfigurationChangeFor: URLRequest(url: url))
            }
        }
    }

    private func warmBackground(of context: WKWebExtensionContext) async {
        guard context.webExtension.hasBackgroundContent else { return }
        await withCheckedContinuation { continuation in
            let waiter = BackgroundStartupWaiter(continuation)
            context.loadBackgroundContent { _ in waiter.finish() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                waiter.finish()
            }
        }
    }

    @MainActor private final class BackgroundStartupWaiter {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func finish() {
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    private func applyGrants(_ record: InstalledBrowserExtension, to context: WKWebExtensionContext) {
        context.grantedPermissions = Dictionary(record.permissions.map {
            (WKWebExtension.Permission(rawValue: $0), Date.distantFuture)
        }, uniquingKeysWith: { first, _ in first })
        context.grantedPermissionMatchPatterns = Dictionary(record.sites.compactMap {
            guard let pattern = try? WKWebExtension.MatchPattern(string: $0) else { return nil }
            return (pattern, Date.distantFuture)
        }, uniquingKeysWith: { first, _ in first })
    }

    func setEnabled(_ enabled: Bool, id: UUID) async {
        guard !isBusy, canModify, let index = installed.firstIndex(where: { $0.id == id }) else { return }
        isBusy = true
        defer { isBusy = false }
        let old = installed[index]
        do {
            var changed = old
            changed.isEnabled = enabled
            // Persist before changing runtime state, restoring the old record on failure.
            var records = installed
            records[index] = changed
            try store.write(records)
            do {
                if enabled { try await load(changed) }
                else if let context = contexts[id] {
                    closePopup(for: context)
                    try controller.unload(context)
                    contexts[id] = nil
                }
            } catch { try? store.write(installed); throw error }
            installed = records
            errors[id] = nil
        } catch { errors[id] = error.localizedDescription }
    }

    func remove(id: UUID) {
        guard !isBusy, canModify, let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = text("extensions_remove_title", installed[index].name)
        alert.addButton(withTitle: text("extensions_remove"))
        alert.addButton(withTitle: text("cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let remaining = installed.filter { $0.id != id }
            try store.write(remaining)
            do {
                if let context = contexts[id] {
                    closePopup(for: context)
                    try controller.unload(context)
                }
            } catch { try? store.write(installed); throw error }
            installed = remaining
            contexts[id] = nil
            errors[id] = nil
            try FileManager.default.removeItem(at: store.resources(for: id))
            Task {
                let types = WKWebExtensionController.allExtensionDataTypes
                let data = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id.uuidString }
                await controller.removeData(ofTypes: types, from: data)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func revokeAccess(id: UUID, permission: String? = nil, site: String? = nil) {
        guard !isBusy, canModify, let index = installed.firstIndex(where: { $0.id == id }) else { return }
        var records = installed
        if let permission { records[index].permissions.removeAll { $0 == permission } }
        if let site { records[index].sites.removeAll { $0 == site } }
        if permission == nil && site == nil {
            records[index].permissions = []
            records[index].sites = []
        }
        do {
            try store.write(records)
            installed = records
            if let context = contexts[id] {
                closePopup(for: context)
                applyGrants(records[index], to: context)
                for case let tab as any WKWebExtensionTab in context.openTabs { context.clearUserGesture(in: tab) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func reviewAccess(id: UUID) {
        guard !isBusy, canModify, let context = contexts[id] else { return }
        let permissions = context.webExtension.requestedPermissions.map(\.rawValue)
        let sites = context.webExtension.allRequestedMatchPatterns.map(\.string)
        guard approve(name: context.webExtension.displayName ?? "", requests: permissions + sites) else { return }
        _ = saveGrants(permissions: permissions, sites: sites, for: context)
    }

    private func saveGrants(permissions: [String] = [], sites: [String] = [], for context: WKWebExtensionContext) -> Bool {
        guard let index = installed.firstIndex(where: { contexts[$0.id] === context }), installed[index].isEnabled else { return false }
        var records = installed
        records[index].permissions = Array(Set(records[index].permissions + permissions)).sorted()
        records[index].sites = Array(Set(records[index].sites + sites)).sorted()
        do {
            try store.write(records)
            installed = records
            applyGrants(records[index], to: context)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func approve(name: String, requests: [String], installing: Bool = false) -> Bool {
        if let approvalHandler { return approvalHandler(name, requests, installing) }
        let alert = NSAlert()
        alert.messageText = text(installing ? "extensions_install_title" : "extensions_access_title", name)
        alert.informativeText = text("extensions_permissions_detail")
        if requests.isEmpty { alert.informativeText += "\n\n" + text("extensions_no_permissions") }
        else {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(180, max(50, requests.count * 20))))
            let list = NSTextView(frame: scroll.bounds)
            list.isEditable = false
            list.isSelectable = true
            list.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            list.string = requests.sorted().joined(separator: "\n")
            list.isVerticallyResizable = true
            scroll.hasVerticalScroller = true
            scroll.documentView = list
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: text(installing ? "extensions_install" : "extensions_allow"))
        alert.addButton(withTitle: text("cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func context(for id: UUID) -> WKWebExtensionContext? { contexts[id] }
    func compatibilityNotice(for id: UUID) -> String? {
        guard let manifest = contexts[id]?.webExtension.manifest,
              let permissions = manifest["permissions"] as? [String],
              permissions.contains("debugger") || permissions.contains("nativeMessaging") else { return nil }
        return text("extensions_side_panel_runtime_limit")
    }
    func diagnostics(for id: UUID) -> String? {
        _ = actionRevision
        let messages = ([errors[id]].compactMap { $0 } + ((contexts[id]?.webExtension.errors ?? []) + (contexts[id]?.errors ?? [])).map(\.localizedDescription))
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    func action(for id: UUID, model: BrowserWindowModel) -> WKWebExtension.Action? {
        guard !model.isPrivate else { return nil }
        return contexts[id]?.action(for: adapter(for: model)?.activeAdapter)
    }
    func performAction(id: UUID, model: BrowserWindowModel) {
        guard !model.isPrivate, let context = contexts[id], let tab = adapter(for: model)?.activeAdapter else { return }
        context.userGesturePerformed(in: tab)
        if context.action(for: tab)?.presentsPopup != true, sidePanelURL(for: id) != nil {
            openSidePanel(id: id, model: model)
            return
        }
        let requestID = UUID()
        pendingActionID = requestID
        guard context.webExtension.hasBackgroundContent else {
            pendingActionID = nil
            context.performAction(for: tab)
            return
        }
        // Some packages connect to their background immediately from the popup. WebKit
        // can reject that connection if the worker has not registered its listeners yet.
        context.loadBackgroundContent { [weak self, weak context, weak tab] error in
            guard let self, self.pendingActionID == requestID else { return }
            self.pendingActionID = nil
            guard let context, let tab, context.isLoaded, tab.owner?.model?.extensionHostWindow != nil else { return }
            if let error { self.errors[id] = error.localizedDescription; return }
            self.errors[id] = nil
            context.userGesturePerformed(in: tab)
            context.performAction(for: tab)
        }
        Task { @MainActor [weak self, weak context] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.pendingActionID == requestID else { return }
            self.pendingActionID = nil
            if context?.isLoaded == true { self.errors[id] = self.text("extensions_background_timeout") }
        }
    }
    func sidePanelURL(for id: UUID) -> URL? {
        guard let context = contexts[id] else { return nil }
        let manifest = context.webExtension.manifest
        let path = (manifest["side_panel"] as? [String: Any])?["default_path"] as? String
            ?? (manifest["sidebar_action"] as? [String: Any])?["default_panel"] as? String
        guard let path, !path.isEmpty, !path.contains("\\"),
              !path.split(separator: "/").contains(".."),
              let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
              url.scheme == context.baseURL.scheme, url.host == context.baseURL.host else { return nil }
        return url
    }

    func openSidePanel(id: UUID, model: BrowserWindowModel) {
        guard !model.isPrivate, let context = contexts[id], let url = sidePanelURL(for: id),
              let configuration = context.webViewConfiguration else { return }
        if model.extensionSidePanel?.id == id { return }
        sidePanelOwners.removeAll { $0.model == nil || $0.model === model }
        sidePanelOwners.append(WeakSidePanelOwner(model))
        model.dismissAIChat()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = _isDebugAssertConfiguration()
        model.extensionSidePanel = BrowserExtensionSidePanel(id: id, title: context.webExtension.displayName ?? "",
            webView: webView, compatibilityNotice: compatibilityNotice(for: id))
        webView.load(URLRequest(url: url))
        model.dismissSettings()
    }

    func openOptions(id: UUID, model: BrowserWindowModel) {
        guard !model.isPrivate, let url = contexts[id]?.optionsPageURL else { return }
        _ = model.openAssistantTab(url: url, inBackground: false, isAICreated: false)
        model.dismissSettings()
    }

    private func closePopup(for context: WKWebExtensionContext) {
        for owner in sidePanelOwners where owner.model?.extensionSidePanel?.id.uuidString == context.uniqueIdentifier {
            owner.model?.extensionSidePanel?.webView.stopLoading()
            owner.model?.extensionSidePanel = nil
        }
        sidePanelOwners.removeAll { $0.model?.extensionSidePanel == nil }
        if activePopup?.webExtensionContext === context { closePopup() }
    }
    private func closePopup() {
        popupSizeObservation = nil
        popupPanel?.delegate = nil
        if let panel = popupPanel { panel.parent?.removeChildWindow(panel) }
        popupPanel?.close()
        popupPanel = nil
        activePopup?.closePopup()
        activePopup = nil
        popupWindow = nil
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === popupPanel else { return }
        closePopup()
    }
    private var focusedWindow: ExtensionWindowAdapter? {
        windows.first { $0.model?.extensionHostWindow?.isKeyWindow == true }
    }
    private var orderedWindows: [ExtensionWindowAdapter] {
        windows.filter { $0.model != nil }.sorted { lhs, rhs in
            lhs === focusedWindow && rhs !== focusedWindow
        }
    }
    private func adapter(for model: BrowserWindowModel) -> ExtensionWindowAdapter? {
        windows.first { $0.model === model }
    }
    func register(_ model: BrowserWindowModel) {
        guard !model.isPrivate, adapter(for: model) == nil else { return }
        let window = ExtensionWindowAdapter(model: model, manager: self)
        windows.append(window)
        controller.didOpenWindow(window)
        window.sync()
        Task { await restore() }
    }
    func prepareTransfer(_ ids: Set<TabID>, from model: BrowserWindowModel) {
        guard let window = adapter(for: model) else { return }
        for (index, tab) in window.adapters.enumerated() where ids.contains(tab.id) {
            transferring[tab.id] = (tab, window, index)
        }
    }
    func isTransferring(_ id: TabID) -> Bool { transferring[id] != nil }
    func takeTransferred(_ id: TabID, into window: ExtensionWindowAdapter) -> (ExtensionTabAdapter, ExtensionWindowAdapter, Int)? {
        guard let (tab, oldWindow, index) = transferring.removeValue(forKey: id) else { return nil }
        tab.owner = window
        return (tab, oldWindow, index)
    }
    func sync(_ model: BrowserWindowModel) { adapter(for: model)?.sync() }
    func unregister(_ model: BrowserWindowModel) {
        model.extensionSidePanel?.webView.stopLoading()
        model.extensionSidePanel = nil
        guard let window = adapter(for: model) else { return }
        for tab in window.adapters { controller.didCloseTab(tab, windowIsClosing: true) }
        controller.didCloseWindow(window)
        windows.removeAll { $0 === window }
        if popupWindow === window {
            closePopup()
        }
    }

    private func reconcileStoredGrants(for context: WKWebExtensionContext) {
        guard canModify, let index = installed.firstIndex(where: { contexts[$0.id] === context }) else { return }
        var records = installed
        let permissions = Set(context.grantedPermissions.keys.map(\.rawValue))
        let sites = Set(context.grantedPermissionMatchPatterns.keys.map(\.string))
        records[index].permissions.removeAll { !permissions.contains($0) }
        records[index].sites.removeAll { !sites.contains($0) }
        guard records != installed else { return }
        do { try store.write(records); installed = records }
        catch { errorMessage = error.localizedDescription }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { orderedWindows }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { focusedWindow }
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        guard !configuration.shouldBePrivate, configuration.windowType == .normal, configuration.tabs.isEmpty,
              let model = (focusedWindow ?? orderedWindows.first)?.model,
              let open = model.openExtensionWindowRequest else {
            completionHandler(nil, CocoaError(.featureUnsupported)); return
        }
        let id = UUID()
        pendingWindows[id] = (configuration, context, completionHandler)
        open(id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if let pending = self?.pendingWindows.removeValue(forKey: id) {
                pending.2(nil, CocoaError(.featureUnsupported))
            }
        }
    }

    func completeWindowRequest(_ id: UUID, model: BrowserWindowModel) {
        guard !model.isPrivate, let pending = pendingWindows.removeValue(forKey: id) else { return }
        guard pending.1.isLoaded else { pending.2(nil, CocoaError(.featureUnsupported)); return }
        register(model)
        guard let window = adapter(for: model) else { pending.2(nil, CocoaError(.featureUnsupported)); return }
        let configuration = pending.0
        let oldIDs = model.tabs.map(\.id)
        let urls = configuration.tabURLs.isEmpty ? [URL(string: "about:blank")!] : configuration.tabURLs
        for (index, url) in urls.enumerated() {
            _ = model.openAssistantTab(url: url, inBackground: index != 0, isAICreated: false)
        }
        for id in oldIDs { model.closeTab(id) }
        let frame = configuration.frame
        if frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
           frame.width > 0, frame.height > 0 { model.extensionHostWindow?.setFrame(frame, display: true) }
        if configuration.shouldBeFocused { model.extensionHostWindow?.makeKeyAndOrderFront(nil) }
        window.setWindowState(configuration.windowState, for: pending.1, completionHandler: { _ in })
        window.sync()
        pending.2(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let window = (configuration.window as? ExtensionWindowAdapter) ?? focusedWindow ?? orderedWindows.first,
              let model = window.model, !model.isPrivate, windows.contains(where: { $0 === window }) else {
            completionHandler(nil, CocoaError(.featureUnsupported)); return
        }
        let tab = model.openAssistantTab(url: configuration.url ?? URL(string: "about:blank")!, inBackground: !configuration.shouldBeActive, isAICreated: false)
        model.setPinned(configuration.shouldBePinned, for: tab.id)
        model.extensionMoveTab(tab.id, to: configuration.index)
        window.sync()
        completionHandler(window.adapters.first { $0.id == tab.id }, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let values = permissions.map(\.rawValue)
        let allowed = approve(name: context.webExtension.displayName ?? "", requests: values) && saveGrants(permissions: values, for: context)
        completionHandler(allowed ? permissions : [], nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        // URL requests are granted only for this runtime; persistent grants use match patterns.
        let allowed = approve(name: context.webExtension.displayName ?? "", requests: urls.map(\.absoluteString)) && context.isLoaded
        completionHandler(allowed ? urls : [], Date().addingTimeInterval(3600))
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let values = patterns.map(\.string)
        let allowed = approve(name: context.webExtension.displayName ?? "", requests: values) && saveGrants(sites: values, for: context)
        completionHandler(allowed ? patterns : [], nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) { actionRevision += 1 }
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let window = (action.associatedTab as? ExtensionTabAdapter)?.owner ?? focusedWindow
        guard let host = window?.model?.extensionHostWindow, context.isLoaded else {
            completionHandler(CocoaError(.featureUnsupported)); return
        }
        closePopup()
        guard let content = action.popupPopover?.contentViewController else {
            completionHandler(CocoaError(.featureUnsupported)); return
        }
        activePopup = action
        popupWindow = window
        let preferred = content.preferredContentSize
        let size = NSSize(width: preferred.width > 0 ? preferred.width : 400,
                          height: preferred.height > 0 ? preferred.height : 500)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = context.webExtension.displayName ?? ""
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.contentMinSize = NSSize(width: 180, height: 100)
        panel.contentViewController = content
        panel.delegate = self
        panel.setFrameTopLeftPoint(NSPoint(x: host.frame.minX + 100, y: host.frame.maxY - 100))
        popupPanel = panel
        popupSizeObservation = content.observe(\.preferredContentSize, options: [.new]) { [weak self, weak panel] _, change in
            guard let size = change.newValue else { return }
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.popupPanel === panel,
                      size.width > 0, size.height > 0 else { return }
                let available = panel.screen?.visibleFrame.size ?? NSSize(width: 800, height: 700)
                panel.setContentSize(NSSize(width: min(size.width, available.width), height: min(size.height, available.height - 40)))
            }
        }
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
    private func text(_ key: String, _ args: CVarArg...) -> String {
        String(format: BrowserLocalization.string(key), arguments: args)
    }
}
