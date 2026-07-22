import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Observation
import OSLog
import WebKit

@MainActor
@Observable
public final class BrowserTab: Identifiable {
    public let id: TabID
    public var title: String
    public var url: URL?
    public var isPinned: Bool
    public var position: Int64
    public var lifecycleState: TabLifecycleState
    public var progress: Double = 0
    public var isLoading = false
    public var canGoBack = false
    public var canGoForward = false
    public var engine: WebEngineSession?
    public var favicon: NSImage?
    var navigationHistory: TabNavigationHistory

    @ObservationIgnored var interactionState: Any?
    @ObservationIgnored var pendingNavigationHistoryIndex: Int?
    @ObservationIgnored var usesPersistedHistoryFallback = false
    @ObservationIgnored var lastInteractionAt = Date()
    @ObservationIgnored var evictionGraceUntil = Date.distantPast
    @ObservationIgnored var engineProtectionReasons: TabProtectionReason = []
    @ObservationIgnored var faviconTask: Task<Void, Never>?
    @ObservationIgnored var browsingHistoryRecordTask: Task<BrowsingHistoryEntry?, Never>?
    var hasLoadedInitialURL = false
    var automaticCrashRecoveries = 0

    public init(snapshot: PersistedTab) {
        id = snapshot.id
        let restoredNavigationHistory = snapshot.navigationHistory
            ?? TabNavigationHistory(url: snapshot.url, title: snapshot.title)
        navigationHistory = restoredNavigationHistory
        title = restoredNavigationHistory.currentEntry?.title ?? snapshot.title
        url = restoredNavigationHistory.currentEntry?.url ?? snapshot.url
        isPinned = snapshot.isPinned
        position = snapshot.position
        lifecycleState = .evicted
        canGoBack = navigationHistory.backIndex != nil
        canGoForward = navigationHistory.forwardIndex != nil
    }

    public var snapshot: PersistedTab {
        PersistedTab(
            id: id,
            title: title,
            url: url,
            isPinned: isPinned,
            position: position,
            navigationHistory: navigationHistory
        )
    }

    public var displayTitle: String {
        if !title.isEmpty && title != "Новая вкладка" { return title }
        return url?.host ?? "Новая вкладка"
    }

    public var domain: String? { url?.host }
}

public struct MediaPermissionPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let tabID: TabID
    public let origin: SiteOrigin
    public let topLevelOrigin: SiteOrigin
    public let kind: MediaPermissionKind

    public var canAlwaysAllow: Bool {
        origin.allowsPersistentSensitivePermission
    }
}

public enum MediaPermissionAction: Sendable {
    case allowOnce
    case alwaysAllow
    case deny
}

public enum BrowsingDataCategory: String, CaseIterable, Identifiable, Sendable {
    case history
    case cookies
    case cache
    case localStorage
    case serviceWorkers
    case sitePermissions
    case downloadHistory
    case favicons

    public var id: Self { self }
}

@MainActor
private struct PendingMediaPermissionRequest {
    let prompt: MediaPermissionPrompt
    let decisionHandler: @MainActor (Bool) -> Void
}

@MainActor
@Observable
public final class BrowserWindowModel: WebEngineEventSink {
    public private(set) var tabs: [BrowserTab] = []
    public var selectedTabID: TabID?
    public var sidebarMode: SidebarMode = .pinned
    public var isSidebarVisible = true
    public var isOmniboxPresented = false
    public private(set) var isNewTabComposerPresented = false
    public var omniboxText = ""
    public var omniboxError: String?
    public var isFindPresented = false
    public var findText = ""
    public var isDownloadsPresented = false
    public private(set) var mediaPermissionPrompt: MediaPermissionPrompt?
    public var isSitePermissionsPresented = false
    public private(set) var sitePermissions: [StoredSitePermission] = []
    public private(set) var isLoadingSitePermissions = false
    public private(set) var sitePermissionsError: String?
    public var isBrowsingHistoryPresented = false
    public private(set) var browsingHistory: [BrowsingHistoryEntry] = []
    public private(set) var browsingHistoryFavicons: [UUID: NSImage] = [:]
    public private(set) var isLoadingBrowsingHistory = false
    public private(set) var browsingHistoryError: String?
    public var isClearBrowsingDataPresented = false
    public var selectedBrowsingDataCategories = Set(BrowsingDataCategory.allCases)
    public private(set) var isClearingBrowsingData = false
    public var clearBrowsingDataStatus: String?
    public private(set) var searchEngine: SearchEngine
    public let downloadManager: DownloadManager
    public let passkeyAccessManager: PasskeyAccessManager
    public let faviconRepository: FaviconRepository

    private let repository: any SessionRepository
    private let sitePermissionRepository: any SitePermissionRepository
    private let browsingHistoryRepository: any BrowsingHistoryRepository
    private var parser: OmniboxParser
    private let lifecyclePolicy = TabLifecyclePolicy()
    private let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    @ObservationIgnored private let lifecycleLogger = Logger(
        subsystem: "Browser",
        category: "lifecycle"
    )
    @ObservationIgnored private let lifecycleSignposter = OSSignposter(
        subsystem: "Browser",
        category: "lifecycle"
    )
    private var closedTabs: [PersistedTab] = []
    private var didRestore = false
    @ObservationIgnored private var isSessionReady = false
    @ObservationIgnored private var pendingExternalURLs: [URL] = []
    private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleTimerTask: Task<Void, Never>?
    @ObservationIgnored private var pressureRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var pressureReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var memoryPressureMonitor: MemoryPressureMonitor?
    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var currentPressure: MemoryPressureLevel = .normal
    @ObservationIgnored private var applicationIsActive = true
    @ObservationIgnored private var acceptsMediaPermissionRequests = true
    @ObservationIgnored private var pressureSequence = 0
    @ObservationIgnored private var appliedPressureSequence = 0
    @ObservationIgnored private var pendingMediaPermissionRequests: [PendingMediaPermissionRequest] = []
    @ObservationIgnored private var sitePermissionManagementTask: Task<Void, Never>?
    @ObservationIgnored private var browsingHistoryManagementTask: Task<Void, Never>?
    @ObservationIgnored private var clearBrowsingDataTask: Task<Void, Never>?

    public init(
        repository: any SessionRepository,
        sitePermissionRepository: any SitePermissionRepository,
        browsingHistoryRepository: any BrowsingHistoryRepository,
        parser: OmniboxParser? = nil,
        downloadManager: DownloadManager? = nil,
        passkeyAccessManager: PasskeyAccessManager? = nil,
        faviconRepository: FaviconRepository? = nil
    ) {
        let storedSearchEngine = UserDefaults.standard
            .string(forKey: "DefaultSearchEngine")
            .flatMap(SearchEngine.init(rawValue:))
            ?? .duckDuckGo
        self.repository = repository
        self.sitePermissionRepository = sitePermissionRepository
        self.browsingHistoryRepository = browsingHistoryRepository
        self.searchEngine = storedSearchEngine
        self.parser = parser ?? OmniboxParser(searchEngine: storedSearchEngine)
        self.downloadManager = downloadManager ?? DownloadManager()
        self.passkeyAccessManager = passkeyAccessManager ?? PasskeyAccessManager()
        self.faviconRepository = faviconRepository ?? FaviconRepository()
    }

    public var activeTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    public var isComposingNewTab: Bool {
        isOmniboxPresented && isNewTabComposerPresented
    }

    public var pinnedTabs: [BrowserTab] {
        tabs.filter(\.isPinned).sorted { $0.position < $1.position }
    }

    public var regularTabs: [BrowserTab] {
        tabs.filter { !$0.isPinned }.sorted { $0.position < $1.position }
    }

    public var matchingTabs: [BrowserTab] {
        let query = omniboxText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return tabs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || ($0.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public func restoreSession() async {
        guard !didRestore else { return }
        didRestore = true
        await downloadManager.restoreHistory()
        startLifecycleMonitoring()

        do {
            if let snapshot = try await repository.load() {
                tabs = snapshot.tabs
                    .filter { $0.url != nil }
                    .sorted { $0.position < $1.position }
                    .map(BrowserTab.init(snapshot:))
                guard !tabs.isEmpty else {
                    sidebarMode = snapshot.sidebarMode
                    isSidebarVisible = snapshot.sidebarMode == .pinned
                    newTab()
                    markSessionReady()
                    return
                }
                selectedTabID = snapshot.selectedTabID.flatMap { selected in
                    tabs.contains { $0.id == selected } ? selected : nil
                } ?? tabs.first?.id
                sidebarMode = snapshot.sidebarMode
                isSidebarVisible = snapshot.sidebarMode == .pinned
                activateSelectedTabIfNeeded()
                markSessionReady()
                return
            }
        } catch {
            omniboxError = "Сессия не восстановлена: \(error.localizedDescription)"
        }

        newTab()
        markSessionReady()
    }

    public func openExternalURL(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        guard isSessionReady else {
            pendingExternalURLs.append(url)
            return
        }
        openExternalWebURL(url)
    }

    public func makeDefaultBrowser() {
        let applicationURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(
            at: applicationURL,
            toOpenURLsWithScheme: "http"
        ) { [weak self] httpError in
            guard httpError == nil else {
                Task { @MainActor [weak self] in
                    self?.showDefaultBrowserResult(error: httpError)
                }
                return
            }
            NSWorkspace.shared.setDefaultApplication(
                at: applicationURL,
                toOpenURLsWithScheme: "https"
            ) { [weak self] httpsError in
                Task { @MainActor [weak self] in
                    self?.showDefaultBrowserResult(error: httpsError)
                }
            }
        }
    }

    public func requestPasskeyAccess() {
        passkeyAccessManager.requestAccess { [weak self] state in
            self?.showPasskeyAccessResult(state)
        }
    }

    public func presentSitePermissions() {
        isSitePermissionsPresented = true
        reloadSitePermissions()
    }

    public func dismissSitePermissions() {
        isSitePermissionsPresented = false
        sitePermissionManagementTask?.cancel()
        sitePermissionManagementTask = nil
    }

    public func revokeSitePermission(_ permission: StoredSitePermission) {
        sitePermissionManagementTask?.cancel()
        isLoadingSitePermissions = true
        sitePermissionsError = nil
        let repository = sitePermissionRepository
        sitePermissionManagementTask = Task { @MainActor [weak self] in
            do {
                try await repository.remove(
                    for: permission.origin,
                    kind: permission.kind
                )
                let permissions = try await repository.permissions()
                guard !Task.isCancelled, let self else { return }
                sitePermissions = permissions
                isLoadingSitePermissions = false
                if permission.decision == .allow {
                    stopMediaCapture(for: [permission.origin])
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoadingSitePermissions = false
                sitePermissionsError = "Не удалось отозвать разрешение: \(error.localizedDescription)"
            }
        }
    }

    public func clearSitePermissions() {
        let allowedOrigins = Set(
            sitePermissions.lazy
                .filter { $0.decision == .allow }
                .map(\.origin)
        )
        sitePermissionManagementTask?.cancel()
        isLoadingSitePermissions = true
        sitePermissionsError = nil
        let repository = sitePermissionRepository
        sitePermissionManagementTask = Task { @MainActor [weak self] in
            do {
                try await repository.removeAll()
                guard !Task.isCancelled, let self else { return }
                sitePermissions = []
                isLoadingSitePermissions = false
                stopMediaCapture(for: allowedOrigins)
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoadingSitePermissions = false
                sitePermissionsError = "Не удалось очистить разрешения: \(error.localizedDescription)"
            }
        }
    }

    public func presentBrowsingHistory() {
        dismissOmnibox()
        isSitePermissionsPresented = false
        sitePermissionManagementTask?.cancel()
        sitePermissionManagementTask = nil
        isBrowsingHistoryPresented = true
        reloadBrowsingHistory()
    }

    public func dismissBrowsingHistory() {
        isBrowsingHistoryPresented = false
        browsingHistoryManagementTask?.cancel()
        browsingHistoryManagementTask = nil
    }

    public func openBrowsingHistoryEntry(_ entry: BrowsingHistoryEntry) {
        dismissBrowsingHistory()
        navigate(to: entry.url)
    }

    public func clearBrowsingHistory() {
        browsingHistoryManagementTask?.cancel()
        isLoadingBrowsingHistory = true
        browsingHistoryError = nil
        let repository = browsingHistoryRepository
        browsingHistoryManagementTask = Task { @MainActor [weak self] in
            do {
                try await repository.removeAll()
                guard !Task.isCancelled, let self else { return }
                browsingHistory = []
                browsingHistoryFavicons = [:]
                isLoadingBrowsingHistory = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoadingBrowsingHistory = false
                browsingHistoryError = "Не удалось очистить историю: \(error.localizedDescription)"
            }
        }
    }

    public func presentClearBrowsingData() {
        dismissOmnibox()
        dismissSitePermissions()
        dismissBrowsingHistory()
        clearBrowsingDataStatus = nil
        isClearBrowsingDataPresented = true
    }

    public func dismissClearBrowsingData() {
        guard !isClearingBrowsingData else { return }
        isClearBrowsingDataPresented = false
        clearBrowsingDataTask?.cancel()
        clearBrowsingDataTask = nil
    }

    public func clearSelectedBrowsingData() {
        guard !selectedBrowsingDataCategories.isEmpty,
              !isClearingBrowsingData
        else { return }

        let categories = selectedBrowsingDataCategories
        let historyRepository = browsingHistoryRepository
        let permissionRepository = sitePermissionRepository
        let faviconRepository = faviconRepository
        isClearingBrowsingData = true
        clearBrowsingDataStatus = nil

        clearBrowsingDataTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var websiteDataTypes: Set<String> = []
                if categories.contains(.cookies) {
                    websiteDataTypes.insert(WKWebsiteDataTypeCookies)
                }
                if categories.contains(.cache) {
                    websiteDataTypes.formUnion([
                        WKWebsiteDataTypeDiskCache,
                        WKWebsiteDataTypeMemoryCache,
                        WKWebsiteDataTypeOfflineWebApplicationCache
                    ])
                }
                if categories.contains(.localStorage) {
                    websiteDataTypes.formUnion([
                        WKWebsiteDataTypeLocalStorage,
                        WKWebsiteDataTypeIndexedDBDatabases,
                        WKWebsiteDataTypeWebSQLDatabases
                    ])
                }
                if categories.contains(.serviceWorkers) {
                    websiteDataTypes.insert(WKWebsiteDataTypeServiceWorkerRegistrations)
                }
                if !websiteDataTypes.isEmpty {
                    await WKWebsiteDataStore.default().removeData(
                        ofTypes: websiteDataTypes,
                        modifiedSince: .distantPast
                    )
                }

                if categories.contains(.history) {
                    try await historyRepository.removeAll()
                    browsingHistory = []
                    browsingHistoryFavicons = [:]
                }
                if categories.contains(.sitePermissions) {
                    try await permissionRepository.removeAll()
                    sitePermissions = []
                }
                if categories.contains(.downloadHistory) {
                    downloadManager.clearInactive()
                    await downloadManager.flushHistory()
                }
                if categories.contains(.favicons) {
                    try await faviconRepository.clearAllCaches()
                    for tab in tabs {
                        tab.faviconTask?.cancel()
                        tab.favicon = nil
                    }
                    browsingHistoryFavicons = [:]
                }

                if !websiteDataTypes.isEmpty {
                    for tab in tabs {
                        tab.engine?.reload()
                    }
                }
                guard !Task.isCancelled else { return }
                isClearingBrowsingData = false
                clearBrowsingDataStatus = "Выбранные данные удалены"
            } catch {
                guard !Task.isCancelled else { return }
                isClearingBrowsingData = false
                clearBrowsingDataStatus = "Часть данных могла быть удалена: \(error.localizedDescription)"
            }
        }
    }

    public func dispatch(_ command: BrowserCommand) {
        switch command {
        case let .newTab(background):
            newTab(background: background)
        case let .closeTab(id):
            closeTab(id)
        case .reopenClosedTab:
            reopenClosedTab()
        case let .selectTab(id):
            selectTab(id)
        case let .moveTab(id, before):
            moveTab(id, before: before)
        case let .pinTab(id, isPinned):
            setPinned(isPinned, for: id)
        case let .load(id, destination):
            navigate(tabID: id, to: destination)
        case let .goBack(id):
            goBack(tabID: id)
        case let .goForward(id):
            goForward(tabID: id)
        case let .reload(id, bypassCache):
            tab(id)?.engine?.reload(bypassingCache: bypassCache)
        case let .stop(id):
            tab(id)?.engine?.stop()
        case .toggleSidebar:
            toggleSidebarMode()
        case .focusOmnibox:
            presentOmnibox()
        case .findInPage:
            isFindPresented = true
        }
    }

    public func handleNavigationSwipe(
        _ direction: NavigationSwipeDirection
    ) -> Bool {
        guard let selectedTabID,
              let tab = tab(selectedTabID),
              tab.pendingNavigationHistoryIndex == nil
        else { return false }

        switch direction {
        case .back:
            guard tab.navigationHistory.backIndex != nil else { return false }
            goBack(tabID: selectedTabID)
        case .forward:
            guard tab.navigationHistory.forwardIndex != nil else { return false }
            goForward(tabID: selectedTabID)
        }
        return tab.pendingNavigationHistoryIndex != nil
    }

    public func newTab(background: Bool = false) {
        guard !background else { return }

        if isComposingNewTab {
            dismissOmnibox()
        } else {
            omniboxError = nil
            omniboxText = ""
            isNewTabComposerPresented = true
            isOmniboxPresented = true
        }
    }

    public func closeTab(_ id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        closedTabs.insert(tabs[index].snapshot, at: 0)
        closedTabs = Array(closedTabs.prefix(50))
        cancelMediaPermissionRequests(for: id)
        dispose(tab: tabs[index])
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedTabID = nil
            dismissOmnibox()
            newTab()
            reconcileLifecycle()
            persist()
            return
        }

        if wasSelected {
            let nextIndex = min(index, tabs.count - 1)
            selectTab(tabs[nextIndex].id)
        }
        normalizePositions()
        reconcileLifecycle()
        persist()
    }

    public func reopenClosedTab() {
        guard let index = closedTabs.firstIndex(where: { $0.url != nil }) else { return }
        var snapshot = closedTabs.remove(at: index)
        snapshot.position = nextPosition
        let restored = BrowserTab(snapshot: snapshot)
        tabs.append(restored)
        selectTab(restored.id)
        persist()
    }

    public func selectTab(_ id: TabID) {
        guard tab(id) != nil else { return }
        let now = Date()
        if let activeTab, activeTab.id != id, activeTab.lifecycleState != .crashed {
            activeTab.lifecycleState = .liveBackground
            activeTab.evictionGraceUntil = max(
                activeTab.evictionGraceUntil,
                now.addingTimeInterval(5)
            )
            activeTab.engine?.refreshMediaPlaybackState()
        }
        selectedTabID = id
        activateSelectedTabIfNeeded()
        if mediaPermissionPrompt?.tabID != id {
            mediaPermissionPrompt = nil
        }
        presentNextMediaPermissionIfPossible()
        omniboxText = activeTab?.url?.absoluteString ?? ""
        reconcileLifecycle(now: now)
        persist()
    }

    public func moveTab(_ id: TabID, before targetID: TabID?) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let moving = tabs.remove(at: sourceIndex)
        if let targetID, let destination = tabs.firstIndex(where: { $0.id == targetID }) {
            tabs.insert(moving, at: destination)
        } else {
            tabs.append(moving)
        }
        normalizePositions()
        persist()
    }

    public func setPinned(_ isPinned: Bool, for id: TabID) {
        guard let tab = tab(id) else { return }
        tab.isPinned = isPinned
        normalizePositions()
        persist()
    }

    public func presentOmnibox(clearText: Bool = false) {
        omniboxError = nil
        isNewTabComposerPresented = false
        if clearText {
            omniboxText = ""
        } else {
            omniboxText = activeTab?.url?.absoluteString ?? ""
        }
        isOmniboxPresented = true
    }

    public func dismissOmnibox() {
        isOmniboxPresented = false
        isNewTabComposerPresented = false
    }

    public func selectSearchEngine(_ searchEngine: SearchEngine) {
        guard self.searchEngine != searchEngine else { return }
        self.searchEngine = searchEngine
        parser = OmniboxParser(searchEngine: searchEngine)
        UserDefaults.standard.set(
            searchEngine.rawValue,
            forKey: "DefaultSearchEngine"
        )
    }

    public func submitOmnibox() {
        let destination = parser.destination(for: omniboxText)
        if isNewTabComposerPresented {
            switch destination {
            case .empty:
                dismissOmnibox()
            case let .blocked(reason):
                omniboxError = reason
            case let .url(url), let .search(url):
                selectTab(appendTab(url: url))
                dismissOmnibox()
            }
            return
        }

        guard let id = selectedTabID else { return }
        navigate(tabID: id, to: destination)
    }

    public func selectOpenTabFromOmnibox(_ id: TabID) {
        dismissOmnibox()
        selectTab(id)
    }

    public func navigate(tabID: TabID, to destination: OmniboxDestination) {
        switch destination {
        case .empty:
            dismissOmnibox()
        case let .url(url), let .search(url):
            guard let tab = tab(tabID) else { return }
            let engine = ensureEngine(for: tab)
            tab.pendingNavigationHistoryIndex = nil
            tab.url = url
            tab.hasLoadedInitialURL = true
            tab.lifecycleState = tab.id == selectedTabID ? .active : .liveBackground
            engine.load(url)
            omniboxText = url.absoluteString
            omniboxError = nil
            dismissOmnibox()
            reconcileLifecycle()
            persist()
        case let .blocked(reason):
            omniboxError = reason
        }
    }

    public func navigate(to url: URL) {
        guard let id = selectedTabID else {
            selectTab(appendTab(url: url))
            dismissOmnibox()
            return
        }
        navigate(tabID: id, to: .url(url))
    }

    private func goBack(tabID: TabID) {
        guard let tab = tab(tabID),
              tab.pendingNavigationHistoryIndex == nil,
              let targetIndex = tab.navigationHistory.backIndex,
              tab.navigationHistory.entries.indices.contains(targetIndex)
        else { return }
        let engine = ensureEngine(for: tab)
        let targetURL = tab.navigationHistory.entries[targetIndex].url
        tab.pendingNavigationHistoryIndex = targetIndex

        if !tab.usesPersistedHistoryFallback,
           engine.backItemURL == targetURL {
            engine.goBack()
        } else {
            tab.usesPersistedHistoryFallback = true
            engine.setNativeBackForwardGesturesEnabled(false)
            tab.hasLoadedInitialURL = true
            engine.loadHistoryEntry(targetURL)
        }
    }

    private func goForward(tabID: TabID) {
        guard let tab = tab(tabID),
              tab.pendingNavigationHistoryIndex == nil,
              let targetIndex = tab.navigationHistory.forwardIndex,
              tab.navigationHistory.entries.indices.contains(targetIndex)
        else { return }
        let engine = ensureEngine(for: tab)
        let targetURL = tab.navigationHistory.entries[targetIndex].url
        tab.pendingNavigationHistoryIndex = targetIndex

        if !tab.usesPersistedHistoryFallback,
           engine.forwardItemURL == targetURL {
            engine.goForward()
        } else {
            tab.usesPersistedHistoryFallback = true
            engine.setNativeBackForwardGesturesEnabled(false)
            tab.hasLoadedInitialURL = true
            engine.loadHistoryEntry(targetURL)
        }
    }

    public func submitFind() {
        activeTab?.engine?.find(findText)
    }

    public func resumeDownload(_ id: UUID) {
        guard let tab = activeTab else { return }
        let engine = ensureEngine(for: tab)
        downloadManager.resume(id, using: engine.webView)
    }

    public func toggleDownloads() {
        isDownloadsPresented.toggle()
        if isDownloadsPresented, sidebarMode == .autoHide {
            isSidebarVisible = true
        }
    }

    public func toggleSidebarMode() {
        sidebarMode = sidebarMode == .pinned ? .autoHide : .pinned
        isSidebarVisible = sidebarMode == .pinned
        persist()
    }

    public func showAutoHideSidebar() {
        guard sidebarMode == .autoHide else { return }
        isSidebarVisible = true
    }

    public func hideAutoHideSidebar() {
        guard sidebarMode == .autoHide,
              !isOmniboxPresented,
              !isDownloadsPresented
        else { return }
        isSidebarVisible = false
    }

    public func webEngineDidChange(_ session: WebEngineSession) {
        guard let tab = tab(session.tabID) else { return }
        tab.title = session.title
        tab.progress = session.estimatedProgress
        tab.isLoading = session.isLoading
        if session.url == tab.navigationHistory.currentEntry?.url {
            tab.navigationHistory.updateCurrentTitle(session.title)
        }
        updateNavigationAvailability(for: tab, session: session)
        let protection = engineProtectionReasons(for: session)
        if protection != tab.engineProtectionReasons {
            tab.engineProtectionReasons = protection
            reconcileLifecycle()
        }
    }

    public func webEngineDidCommit(_ session: WebEngineSession) {
        guard let tab = tab(session.tabID), let committedURL = session.url else { return }
        let previousCacheKey = tab.url.flatMap(FaviconCacheKey.make(for:))
        tab.url = committedURL
        tab.title = session.title
        if let targetIndex = tab.pendingNavigationHistoryIndex {
            _ = tab.navigationHistory.move(
                to: targetIndex,
                committedURL: committedURL,
                title: session.title
            )
        } else if session.committedNavigationWasBackForward {
            if let backIndex = tab.navigationHistory.backIndex,
               tab.navigationHistory.entries[backIndex].url == committedURL {
                _ = tab.navigationHistory.move(
                    to: backIndex,
                    committedURL: committedURL,
                    title: session.title
                )
            } else if let forwardIndex = tab.navigationHistory.forwardIndex,
                      tab.navigationHistory.entries[forwardIndex].url == committedURL {
                _ = tab.navigationHistory.move(
                    to: forwardIndex,
                    committedURL: committedURL,
                    title: session.title
                )
            } else {
                tab.navigationHistory.recordNavigation(
                    url: committedURL,
                    title: session.title
                )
            }
        } else {
            tab.navigationHistory.recordNavigation(
                url: committedURL,
                title: session.title
            )
        }
        tab.pendingNavigationHistoryIndex = nil
        updateNavigationAvailability(for: tab, session: session)
        let currentCacheKey = tab.url.flatMap(FaviconCacheKey.make(for:))
        if previousCacheKey != currentCacheKey {
            tab.faviconTask?.cancel()
            tab.favicon = nil
        }
        if tab.id == selectedTabID {
            omniboxText = session.url?.absoluteString ?? ""
        }
        cancelStaleMediaPermissionRequests(
            for: tab.id,
            currentTopLevelOrigin: SiteOrigin(url: session.url)
        )
        recordBrowsingHistoryVisit(
            for: tab,
            url: committedURL,
            title: session.title
        )
        persist()
    }

    public func webEngineDidFinish(_ session: WebEngineSession) {
        guard let tab = tab(session.tabID),
              let finishedURL = session.url,
              ["http", "https"].contains(finishedURL.scheme?.lowercased() ?? ""),
              let recordTask = tab.browsingHistoryRecordTask
        else { return }

        let title = session.title
        let repository = browsingHistoryRepository
        Task { @MainActor [weak self, weak tab] in
            guard let record = await recordTask.value,
                  let self,
                  let tab,
                  tab.url == finishedURL
            else { return }
            try? await repository.updateTitle(title, for: record.id)
            if isBrowsingHistoryPresented {
                reloadBrowsingHistory()
            }
        }
    }

    public func webEngineDidFailNavigation(_ session: WebEngineSession) {
        guard let tab = tab(session.tabID) else { return }
        tab.pendingNavigationHistoryIndex = nil
        updateNavigationAvailability(for: tab, session: session)
    }

    public func webEngineDidCrash(_ session: WebEngineSession) {
        guard let tab = tab(session.tabID) else { return }
        tab.pendingNavigationHistoryIndex = nil
        cancelMediaPermissionRequests(for: tab.id)
        tab.lifecycleState = .crashed
        tab.isLoading = false

        if tab.id == selectedTabID, tab.automaticCrashRecoveries == 0 {
            tab.automaticCrashRecoveries += 1
            session.reload()
            tab.lifecycleState = .active
        } else if tab.id != selectedTabID {
            session.invalidate()
            tab.engine = nil
        }
    }

    public func webEngineIsActive(_ session: WebEngineSession) -> Bool {
        session.tabID == selectedTabID
    }

    public func webEngine(
        _ session: WebEngineSession,
        requestsMediaPermissionFor origin: SiteOrigin,
        topLevelOrigin: SiteOrigin,
        kind: MediaPermissionKind,
        decisionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let requestID = UUID()
        let tabID = session.tabID
        let sitePermissionRepository = sitePermissionRepository

        Task { @MainActor [weak self, weak session] in
            let storedDecision = try? await sitePermissionRepository.decision(
                for: origin,
                kind: kind
            )
            guard let self,
                  let session,
                  acceptsMediaPermissionRequests,
                  tab(tabID)?.engine === session,
                  SiteOrigin(url: session.url) == topLevelOrigin
            else {
                decisionHandler(false)
                return
            }

            if let storedDecision {
                if storedDecision == .deny {
                    decisionHandler(false)
                    return
                }
                if origin.allowsPersistentSensitivePermission {
                    decisionHandler(true)
                    return
                }
            }

            let prompt = MediaPermissionPrompt(
                id: requestID,
                tabID: tabID,
                origin: origin,
                topLevelOrigin: topLevelOrigin,
                kind: kind
            )
            pendingMediaPermissionRequests.append(
                PendingMediaPermissionRequest(
                    prompt: prompt,
                    decisionHandler: decisionHandler
                )
            )
            presentNextMediaPermissionIfPossible()
        }
    }

    public func resolveMediaPermission(_ action: MediaPermissionAction) {
        guard let prompt = mediaPermissionPrompt,
              let index = pendingMediaPermissionRequests.firstIndex(where: {
                  $0.prompt.id == prompt.id
              })
        else { return }

        let request = pendingMediaPermissionRequests.remove(at: index)
        mediaPermissionPrompt = nil

        switch action {
        case .allowOnce:
            request.decisionHandler(true)
            presentNextMediaPermissionIfPossible()
        case .alwaysAllow where prompt.canAlwaysAllow:
            persistPermissionDecision(.allow, for: request)
        case .alwaysAllow:
            request.decisionHandler(true)
            presentNextMediaPermissionIfPossible()
        case .deny:
            persistPermissionDecision(.deny, for: request)
        }
    }

    public func webEngine(
        _ session: WebEngineSession,
        didDiscoverFaviconAt iconURL: URL
    ) {
        guard let tab = tab(session.tabID), let pageURL = session.url ?? tab.url else {
            return
        }
        let expectedKey = FaviconCacheKey.make(for: pageURL)
        tab.faviconTask?.cancel()
        let repository = faviconRepository
        tab.faviconTask = Task { @MainActor [weak tab] in
            guard let image = await repository.image(for: iconURL, pageURL: pageURL),
                  !Task.isCancelled,
                  let tab,
                  tab.url.flatMap(FaviconCacheKey.make(for:)) == expectedKey
            else { return }
            tab.favicon = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        }
    }

    public func webEngine(
        _ session: WebEngineSession,
        createNewTabWith configuration: WKWebViewConfiguration,
        request: URLRequest?
    ) -> WKWebView? {
        let id = TabID()
        let newTab = BrowserTab(
            snapshot: PersistedTab(
                id: id,
                title: "Новая вкладка",
                url: request?.url,
                isPinned: false,
                position: nextPosition
            )
        )
        let engine = WebEngineSession(
            tabID: id,
            configuration: configuration,
            downloadManager: downloadManager
        )
        engine.eventSink = self
        newTab.engine = engine
        newTab.lifecycleState = .active
        newTab.hasLoadedInitialURL = true
        tabs.append(newTab)
        selectTab(id)
        reconcileLifecycle()
        persist()
        return engine.webView
    }

    public func webEngineRequestedClose(_ session: WebEngineSession) {
        closeTab(session.tabID)
    }

    private func presentNextMediaPermissionIfPossible() {
        guard mediaPermissionPrompt == nil, let selectedTabID else { return }
        mediaPermissionPrompt = pendingMediaPermissionRequests.first {
            $0.prompt.tabID == selectedTabID
        }?.prompt
    }

    private func persistPermissionDecision(
        _ decision: SitePermissionDecision,
        for request: PendingMediaPermissionRequest
    ) {
        request.decisionHandler(decision == .allow)
        let repository = sitePermissionRepository
        let prompt = request.prompt
        Task {
            try? await repository.save(
                decision,
                for: prompt.origin,
                kind: prompt.kind
            )
        }
        presentNextMediaPermissionIfPossible()
    }

    private func cancelMediaPermissionRequests(for tabID: TabID) {
        cancelMediaPermissionRequests {
            $0.prompt.tabID == tabID
        }
    }

    private func cancelStaleMediaPermissionRequests(
        for tabID: TabID,
        currentTopLevelOrigin: SiteOrigin?
    ) {
        cancelMediaPermissionRequests {
            $0.prompt.tabID == tabID
                && $0.prompt.topLevelOrigin != currentTopLevelOrigin
        }
    }

    private func cancelAllMediaPermissionRequests() {
        cancelMediaPermissionRequests { _ in true }
    }

    private func cancelMediaPermissionRequests(
        where shouldCancel: (PendingMediaPermissionRequest) -> Bool
    ) {
        let cancelled = pendingMediaPermissionRequests.filter(shouldCancel)
        guard !cancelled.isEmpty else { return }
        let cancelledIDs = Set(cancelled.map(\.prompt.id))
        pendingMediaPermissionRequests.removeAll(where: shouldCancel)
        if let prompt = mediaPermissionPrompt,
           cancelledIDs.contains(prompt.id) {
            mediaPermissionPrompt = nil
        }
        cancelled.forEach { $0.decisionHandler(false) }
        presentNextMediaPermissionIfPossible()
    }

    private var nextPosition: Int64 {
        (tabs.map(\.position).max() ?? 0) + 1024
    }

    private func appendTab(url: URL) -> TabID {
        let id = TabID()
        tabs.append(
            BrowserTab(
                snapshot: PersistedTab(
                    id: id,
                    title: "Новая вкладка",
                    url: url,
                    isPinned: false,
                    position: nextPosition
                )
            )
        )
        return id
    }

    private func tab(_ id: TabID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    private func updateNavigationAvailability(
        for tab: BrowserTab,
        session: WebEngineSession? = nil
    ) {
        let nativeBack = tab.usesPersistedHistoryFallback
            ? false
            : (session?.canGoBack ?? false)
        let nativeForward = tab.usesPersistedHistoryFallback
            ? false
            : (session?.canGoForward ?? false)
        tab.canGoBack = tab.navigationHistory.backIndex != nil || nativeBack
        tab.canGoForward = tab.navigationHistory.forwardIndex != nil || nativeForward
    }

    @discardableResult
    private func ensureEngine(for tab: BrowserTab) -> WebEngineSession {
        if let engine = tab.engine { return engine }
        let interval = lifecycleSignposter.beginInterval("Tab restore")
        defer { lifecycleSignposter.endInterval("Tab restore", interval) }
        tab.lifecycleState = .restoring
        let engine = WebEngineSession(
            tabID: tab.id,
            downloadManager: downloadManager
        )
        engine.eventSink = self
        tab.engine = engine
        if let interactionState = tab.interactionState {
            tab.hasLoadedInitialURL = engine.restoreInteractionState(interactionState)
            tab.interactionState = nil
        }
        return engine
    }

    private func activateSelectedTabIfNeeded() {
        guard let tab = activeTab else { return }
        let engine = ensureEngine(for: tab)
        engine.setMediaPlaybackSuspended(false)
        tab.lifecycleState = .active
        tab.lastInteractionAt = Date()
        tab.evictionGraceUntil = tab.lastInteractionAt.addingTimeInterval(30)
        if !tab.hasLoadedInitialURL, let url = tab.url {
            tab.hasLoadedInitialURL = true
            engine.load(url)
        }
        engine.refreshMediaPlaybackState()
    }

    public func setApplicationActive(_ isActive: Bool) {
        guard applicationIsActive != isActive else { return }
        applicationIsActive = isActive
        reconcileLifecycle()
    }

    public func stopLifecycleMonitoring() {
        acceptsMediaPermissionRequests = false
        pressureSequence += 1
        sitePermissionManagementTask?.cancel()
        sitePermissionManagementTask = nil
        browsingHistoryManagementTask?.cancel()
        browsingHistoryManagementTask = nil
        clearBrowsingDataTask?.cancel()
        clearBrowsingDataTask = nil
        lifecycleTimerTask?.cancel()
        lifecycleTimerTask = nil
        pressureRecoveryTask?.cancel()
        pressureRecoveryTask = nil
        pressureReconcileTask?.cancel()
        pressureReconcileTask = nil
        memoryPressureMonitor?.cancel()
        memoryPressureMonitor = nil
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        cancelAllMediaPermissionRequests()
    }

    private func startLifecycleMonitoring() {
        guard memoryPressureMonitor == nil else { return }
        acceptsMediaPermissionRequests = true

        let monitor = MemoryPressureMonitor { [weak self] pressure in
            self?.handleMemoryPressure(pressure)
        }
        memoryPressureMonitor = monitor
        monitor.start()

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileLifecycle()
            }
        }

        lifecycleTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.refreshBackgroundMediaState { [weak self] in
                    self?.reconcileLifecycle(mediaStateIsFresh: true)
                }
            }
        }
    }

    private func reloadSitePermissions() {
        sitePermissionManagementTask?.cancel()
        isLoadingSitePermissions = true
        sitePermissionsError = nil
        let repository = sitePermissionRepository
        sitePermissionManagementTask = Task { @MainActor [weak self] in
            do {
                let permissions = try await repository.permissions()
                guard !Task.isCancelled, let self else { return }
                sitePermissions = permissions
                isLoadingSitePermissions = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoadingSitePermissions = false
                sitePermissionsError = "Не удалось загрузить разрешения: \(error.localizedDescription)"
            }
        }
    }

    private func reloadBrowsingHistory() {
        browsingHistoryManagementTask?.cancel()
        isLoadingBrowsingHistory = true
        browsingHistoryError = nil
        let repository = browsingHistoryRepository
        let faviconRepository = faviconRepository
        browsingHistoryManagementTask = Task { @MainActor [weak self] in
            do {
                let entries = try await repository.recent(limit: 500)
                guard !Task.isCancelled, let self else { return }
                browsingHistory = entries
                browsingHistoryFavicons = [:]
                isLoadingBrowsingHistory = false

                var imagesByOrigin: [String: NSImage] = [:]
                var checkedOrigins: Set<String> = []
                for entry in entries {
                    guard !Task.isCancelled,
                          let key = FaviconCacheKey.make(for: entry.url)
                    else { continue }
                    if checkedOrigins.insert(key).inserted,
                       let image = await faviconRepository.cachedImage(for: entry.url) {
                        imagesByOrigin[key] = NSImage(
                            cgImage: image,
                            size: NSSize(width: image.width, height: image.height)
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                browsingHistoryFavicons = Dictionary(
                    uniqueKeysWithValues: entries.compactMap { entry in
                        guard let key = FaviconCacheKey.make(for: entry.url),
                              let image = imagesByOrigin[key]
                        else { return nil }
                        return (entry.id, image)
                    }
                )
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoadingBrowsingHistory = false
                browsingHistoryError = "Не удалось загрузить историю: \(error.localizedDescription)"
            }
        }
    }

    private func recordBrowsingHistoryVisit(
        for tab: BrowserTab,
        url: URL,
        title: String
    ) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        let repository = browsingHistoryRepository
        tab.browsingHistoryRecordTask = Task {
            try? await repository.recordVisit(
                url: url,
                title: title,
                visitedAt: Date()
            )
        }
    }

    private func stopMediaCapture(for origins: Set<SiteOrigin>) {
        guard !origins.isEmpty else { return }
        for tab in tabs {
            guard let engine = tab.engine,
                  let origin = SiteOrigin(url: engine.url),
                  origins.contains(origin)
            else { continue }
            engine.stopMediaCapture()
        }
    }

    private func markSessionReady() {
        isSessionReady = true
        let queuedURLs = pendingExternalURLs
        pendingExternalURLs.removeAll()
        for url in queuedURLs {
            openExternalWebURL(url)
        }
    }

    private func openExternalWebURL(_ url: URL) {
        if activeTab?.url != nil {
            selectTab(appendTab(url: url))
            dismissOmnibox()
            return
        }
        navigate(to: url)
    }

    private func showDefaultBrowserResult(error: (any Error)?) {
        let alert = NSAlert()
        if let error {
            alert.messageText = "Не удалось изменить браузер по умолчанию"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        } else {
            let applicationURL = Bundle.main.bundleURL.standardizedFileURL
            let httpHandler = NSWorkspace.shared.urlForApplication(
                toOpen: URL(string: "http://example.com")!
            )?.standardizedFileURL
            let httpsHandler = NSWorkspace.shared.urlForApplication(
                toOpen: URL(string: "https://example.com")!
            )?.standardizedFileURL
            if httpHandler == applicationURL, httpsHandler == applicationURL {
                alert.messageText = "Browser назначен браузером по умолчанию"
                alert.informativeText = "Ссылки HTTP и HTTPS будут открываться в Browser."
            } else {
                alert.messageText = "macOS не подтвердила изменение"
                alert.informativeText = "Проверьте браузер по умолчанию в Системных настройках."
                alert.alertStyle = .warning
            }
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showPasskeyAccessResult(_ state: PasskeyAccessState) {
        let alert = NSAlert()
        switch state {
        case .authorized:
            alert.messageText = "Ключи входа доступны"
            alert.informativeText = "WebKit сможет использовать passkeys из Keychain и совместимых менеджеров на сайтах с WebAuthn."
        case .denied:
            alert.messageText = "Доступ к ключам входа запрещён"
            alert.informativeText = "Разрешение можно изменить в настройках конфиденциальности macOS."
            alert.alertStyle = .warning
        case .notDetermined:
            alert.messageText = "Разрешение не выбрано"
            alert.informativeText = "Повторите запрос и подтвердите системный диалог macOS."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func handleMemoryPressure(_ pressure: MemoryPressureLevel) {
        currentPressure = pressure
        lifecycleLogger.notice("Memory pressure changed; reconciling tabs")
        Task {
            await faviconRepository.clearMemoryCache()
        }
        pressureSequence += 1
        let sequence = pressureSequence

        refreshBackgroundMediaState { [weak self] in
            self?.applyMemoryPressure(pressure, sequence: sequence)
        }

        pressureReconcileTask?.cancel()
        pressureReconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.applyMemoryPressure(pressure, sequence: sequence)
        }
    }

    private func applyMemoryPressure(
        _ pressure: MemoryPressureLevel,
        sequence: Int
    ) {
        guard sequence == pressureSequence,
              appliedPressureSequence != sequence
        else { return }
        appliedPressureSequence = sequence
        pressureReconcileTask?.cancel()
        pressureReconcileTask = nil
        reconcileLifecycle(pressure: pressure, mediaStateIsFresh: true)
        if pressure == .critical {
            persist()
        }

        pressureRecoveryTask?.cancel()
        pressureRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            currentPressure = .normal
            reconcileLifecycle()
        }
    }

    private func refreshBackgroundMediaState(
        completion: (@MainActor () -> Void)? = nil
    ) {
        let backgroundIDs = tabs
            .filter { $0.id != selectedTabID }
            .map(\.id)
        refreshMediaState(for: backgroundIDs, completion: completion)
    }

    private func refreshMediaState(
        for tabIDs: [TabID],
        completion: (@MainActor () -> Void)? = nil
    ) {
        let requestedIDs = Set(tabIDs)
        let engines = tabs.compactMap { tab in
            requestedIDs.contains(tab.id) ? tab.engine : nil
        }
        guard !engines.isEmpty else {
            completion?()
            return
        }

        var remaining = engines.count
        for engine in engines {
            engine.refreshMediaPlaybackState {
                remaining -= 1
                if remaining == 0 {
                    completion?()
                }
            }
        }
    }

    private func reconcileLifecycle(
        now: Date = Date(),
        pressure: MemoryPressureLevel? = nil,
        mediaStateIsFresh: Bool = false
    ) {
        let effectivePressure = pressure ?? currentPressure
        let snapshots = tabs.map { tab in
            TabLifecycleSnapshot(
                id: tab.id,
                state: tab.lifecycleState,
                lastInteractionAt: tab.lastInteractionAt,
                protection: protectionReasons(for: tab, now: now)
            )
        }
        let actions = lifecyclePolicy.actions(
            for: snapshots,
            selectedTabID: selectedTabID,
            now: now,
            physicalMemoryBytes: physicalMemoryBytes,
            pressure: effectivePressure,
            thermalState: currentThermalState,
            applicationIsActive: applicationIsActive
        )

        let evictionIDs = actions.compactMap { action -> TabID? in
            guard case let .evict(id) = action else { return nil }
            return id
        }
        if !mediaStateIsFresh, !evictionIDs.isEmpty {
            refreshMediaState(for: evictionIDs) { [weak self] in
                self?.reconcileLifecycle(
                    pressure: effectivePressure,
                    mediaStateIsFresh: true
                )
            }
            return
        }

        for action in actions {
            switch action {
            case let .suspend(id):
                suspend(tabID: id)
            case let .resume(id):
                resume(tabID: id)
            case let .evict(id):
                evict(tabID: id)
            }
        }
    }

    private func suspend(tabID: TabID) {
        guard let tab = tab(tabID),
              tab.id != selectedTabID,
              tab.lifecycleState == .liveBackground,
              let engine = tab.engine
        else { return }
        tab.lifecycleState = .suspended
        engine.setMediaPlaybackSuspended(true)
    }

    private func resume(tabID: TabID) {
        guard let tab = tab(tabID), let engine = tab.engine else { return }
        engine.setMediaPlaybackSuspended(false)
        tab.lifecycleState = tab.id == selectedTabID ? .active : .liveBackground
    }

    private func evict(tabID: TabID) {
        guard let tab = tab(tabID), tab.id != selectedTabID else { return }
        guard protectionReasons(for: tab, now: Date()).isEmpty else { return }
        let interval = lifecycleSignposter.beginInterval("Tab eviction")
        defer { lifecycleSignposter.endInterval("Tab eviction", interval) }

        if let engine = tab.engine {
            tab.url = engine.url ?? tab.url
            if engine.title != "Новая вкладка" {
                tab.title = engine.title
            }
            tab.interactionState = engine.captureInteractionState()
            engine.setMediaPlaybackSuspended(false)
            engine.invalidate()
        }
        tab.engine = nil
        tab.engineProtectionReasons = []
        tab.lifecycleState = .evicted
        tab.isLoading = false
        tab.progress = 0
        updateNavigationAvailability(for: tab)
        lifecycleLogger.debug("Evicted a background tab")
    }

    private func dispose(tab: BrowserTab) {
        tab.faviconTask?.cancel()
        tab.interactionState = nil
        tab.engine?.setMediaPlaybackSuspended(false)
        tab.engine?.invalidate()
        tab.engine = nil
    }

    private func protectionReasons(
        for tab: BrowserTab,
        now: Date
    ) -> TabProtectionReason {
        var reasons = tab.engineProtectionReasons
        if tab.id == selectedTabID {
            reasons.insert(.active)
        }
        if now < tab.evictionGraceUntil {
            reasons.insert(.gracePeriod)
        }
        return reasons
    }

    private func engineProtectionReasons(
        for session: WebEngineSession
    ) -> TabProtectionReason {
        var reasons: TabProtectionReason = []
        if session.isPlayingMedia { reasons.insert(.audibleMedia) }
        if session.hasActiveCapture { reasons.insert(.capture) }
        if session.isElementFullscreen { reasons.insert(.fullscreen) }
        if session.hasPendingUIFlow { reasons.insert(.pendingUIFlow) }
        return reasons
    }

    private var currentThermalState: LifecycleThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .serious
        }
    }

    private func normalizePositions() {
        for (index, tab) in tabs.enumerated() {
            tab.position = Int64(index + 1) * 1024
        }
    }

    private func persist() {
        let snapshot = BrowserSessionSnapshot(
            selectedTabID: selectedTabID,
            sidebarMode: sidebarMode,
            tabs: tabs.map(\.snapshot)
        )
        let repository = repository
        let previousSave = persistenceTask
        persistenceTask = Task {
            await previousSave?.value
            try? await repository.save(snapshot)
        }
    }
}
