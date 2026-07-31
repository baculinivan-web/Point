import AppKit
import BrowserAI
import BrowserCore
import BrowserEngine
import BrowserPersistence
import BrowserUI
import SwiftUI
import WebKit

private enum BrowserSceneID {
    static let standard = "browser-window"
    static let privateBrowsing = "private-browser-window"
    static let aiChat = "ai-chat-window"
}

@main
@MainActor
struct BrowserApp: App {
    @NSApplicationDelegateAdaptor(BrowserApplicationDelegate.self)
    private var applicationDelegate
    private let runtime: BrowserRuntime

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false

        let runtime = BrowserRuntime()
        self.runtime = runtime
        applicationDelegate.runtime = runtime
    }

    var body: some Scene {
        WindowGroup(id: BrowserSceneID.standard) {
            BrowserWindowScene(runtime: runtime, isPrivate: false)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            BrowserCommands()
        }

        WindowGroup(
            BrowserLocalization.string("private_window"),
            id: BrowserSceneID.privateBrowsing
        ) {
            BrowserWindowScene(runtime: runtime, isPrivate: true)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)

        WindowGroup(
            BrowserLocalization.string("ai_chat_window_title"),
            id: BrowserSceneID.aiChat,
            for: UUID.self
        ) { $token in
            AIChatWindowView(token: token)
        }
        .defaultSize(width: 440, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            BrowserSettingsView()
        }
    }
}

@MainActor
private final class BrowserRuntime {
    let downloadManager: DownloadManager

    private let persistenceController: BrowserPersistenceController?
    private let browsingHistoryRepository: any BrowsingHistoryRepository
    private let bookmarkRepository: any BookmarkRepository
    private lazy var maintenance = BrowsingDataMaintenance(
        browsingHistoryRepository: browsingHistoryRepository
    )
    private var privateDownloadManagers: [WeakDownloadManager] = []
    private var windowModels: [WeakBrowserWindowModel] = []
    private var standardWindowCount = 0
    private var hasClaimedOnboarding = false

    init() {
        downloadManager = DownloadManager(
            historyRepository: FileDownloadHistoryRepository()
        )
        let controller = try? BrowserPersistenceController()
        persistenceController = controller
        browsingHistoryRepository = controller?.browsingHistoryRepository()
            ?? FileBrowsingHistoryRepository()
        bookmarkRepository = FileBookmarkRepository()
    }

    func makeWindowModel(isPrivate: Bool) -> BrowserWindowModel {
        if isPrivate {
            let privateDownloadManager = DownloadManager()
            privateDownloadManagers.removeAll { $0.value == nil }
            privateDownloadManagers.append(
                WeakDownloadManager(privateDownloadManager)
            )
            return register(
                BrowserWindowModel(
                    repository: InMemorySessionRepository(),
                    sitePermissionRepository: InMemorySitePermissionRepository(),
                    browsingHistoryRepository: InMemoryBrowsingHistoryRepository(),
                    bookmarkRepository: InMemoryBookmarkRepository(),
                    downloadManager: privateDownloadManager,
                    faviconRepository: FaviconRepository(persistsToDisk: false),
                    isPrivate: true,
                    websiteDataStore: .nonPersistent()
                )
            )
        }

        let isPrimaryWindow = standardWindowCount == 0
        let windowID = isPrimaryWindow
            ? BrowserPersistenceController.primaryWindowID
            : UUID()
        standardWindowCount += 1
        let sessionRepository: any SessionRepository
        if let persistenceController {
            sessionRepository = persistenceController.sessionRepository(
                windowID: windowID,
                migratesLegacySession: isPrimaryWindow
            )
        } else if isPrimaryWindow {
            sessionRepository = FileSessionRepository()
        } else {
            sessionRepository = InMemorySessionRepository(
                persistsWithinLifetime: true
            )
        }

        return register(
            BrowserWindowModel(
                repository: sessionRepository,
                sitePermissionRepository: FileSitePermissionRepository(),
                browsingHistoryRepository: browsingHistoryRepository,
                bookmarkRepository: bookmarkRepository,
                downloadManager: downloadManager,
                isPrivate: false,
                websiteDataStore: .default()
            )
        )
    }

    private func register(_ model: BrowserWindowModel) -> BrowserWindowModel {
        windowModels.removeAll { $0.value == nil }
        windowModels.append(WeakBrowserWindowModel(model))
        return model
    }

    /// Decides whether this window presents the welcome tour.
    ///
    /// Only one standard window may claim it per launch, and only when the
    /// person is genuinely new: a window that restored a stored session belongs
    /// to an existing install, so the tour is marked as seen instead of shown.
    func claimOnboardingPresentation(hasRestoredSession: Bool) -> Bool {
        guard !hasClaimedOnboarding, !BrowserOnboarding.isComplete else { return false }
        hasClaimedOnboarding = true
        guard !hasRestoredSession else {
            BrowserOnboarding.markComplete()
            return false
        }
        return true
    }

    func performMaintenanceIfNeeded() async {
        await maintenance.start()
    }

    func prepareForTermination() async {
        privateDownloadManagers.removeAll { $0.value == nil }
        windowModels.removeAll { $0.value == nil }

        for model in windowModels.compactMap(\.value) {
            await model.closeAllTabsForTermination()
        }

        await downloadManager.flushHistory()
        for manager in privateDownloadManagers.compactMap(\.value) {
            await manager.flushHistory()
        }

        for window in NSApp.windows where window.isVisible {
            window.close()
        }
    }

    var activeDownloadCount: Int {
        privateDownloadManagers.removeAll { $0.value == nil }
        return downloadManager.activeDownloadCount
            + privateDownloadManagers.compactMap(\.value)
                .reduce(0) { $0 + $1.activeDownloadCount }
    }
}

@MainActor
private final class WeakDownloadManager {
    weak var value: DownloadManager?

    init(_ value: DownloadManager) {
        self.value = value
    }
}

@MainActor
private final class WeakBrowserWindowModel {
    weak var value: BrowserWindowModel?

    init(_ value: BrowserWindowModel) {
        self.value = value
    }
}

private struct BrowserWindowScene: View {
    @Environment(\.openWindow) private var openWindow
    @State private var model: BrowserWindowModel
    @State private var isOnboardingPresented = false
    private let runtime: BrowserRuntime
    private let isPrivate: Bool

    init(runtime: BrowserRuntime, isPrivate: Bool) {
        self.runtime = runtime
        self.isPrivate = isPrivate
        _model = State(
            initialValue: runtime.makeWindowModel(isPrivate: isPrivate)
        )
    }

    var body: some View {
        BrowserWindowView(
            model: model,
            isOnboardingPresented: $isOnboardingPresented
        )
            .task {
                model.openWindowRequest = { shouldOpenPrivateWindow in
                    openWindow(
                        id: shouldOpenPrivateWindow
                            ? BrowserSceneID.privateBrowsing
                            : BrowserSceneID.standard
                    )
                }
                model.openAIChatWindowRequest = { token in
                    openWindow(id: BrowserSceneID.aiChat, value: token)
                }
                if !isPrivate {
                    await runtime.performMaintenanceIfNeeded()
                }
                await model.restoreSession()
                if !isPrivate,
                   let transferredTabs = BrowserWindowTransferCenter.shared
                    .claimNextBatch() {
                    model.adoptTransferredTabs(transferredTabs)
                }
                if !isPrivate, runtime.claimOnboardingPresentation(
                    hasRestoredSession: model.didRestorePersistedSession
                ) {
                    isOnboardingPresented = true
                }
            }
            .onOpenURL { url in
                guard !isPrivate else { return }
                model.openExternalURL(url)
            }
    }
}

@MainActor
private final class BrowsingDataMaintenance {
    private static let lastRunKey = "BrowsingDataMaintenanceLastRun"
    private static let runInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let historyRetention: TimeInterval = 90 * 24 * 60 * 60

    private let browsingHistoryRepository: any BrowsingHistoryRepository
    private var isRunning = false
    private var monitorTask: Task<Void, Never>?

    init(browsingHistoryRepository: any BrowsingHistoryRepository) {
        self.browsingHistoryRepository = browsingHistoryRepository
    }

    func start() async {
        await runIfNeeded()
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                guard !Task.isCancelled, let self else { return }
                await runIfNeeded()
            }
        }
    }

    func runIfNeeded(now: Date = Date()) async {
        guard !isRunning else { return }
        let lastRun = UserDefaults.standard.object(
            forKey: Self.lastRunKey
        ) as? Date
        guard lastRun.map({
            now.timeIntervalSince($0) >= Self.runInterval
        }) ?? true else { return }

        isRunning = true
        defer { isRunning = false }
        do {
            try await browsingHistoryRepository.removeVisits(
                before: now.addingTimeInterval(-Self.historyRetention)
            )
            await WKWebsiteDataStore.default().removeData(
                ofTypes: [
                    WKWebsiteDataTypeDiskCache,
                    WKWebsiteDataTypeMemoryCache,
                    WKWebsiteDataTypeOfflineWebApplicationCache
                ],
                modifiedSince: .distantPast
            )
            UserDefaults.standard.set(now, forKey: Self.lastRunKey)
        } catch {
            // A failed maintenance pass remains eligible on the next launch.
        }
    }
}

@MainActor
private final class BrowserApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: BrowserRuntime?
    private var isTerminationReplyPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        normalizeCloseWindowShortcut()
        DispatchQueue.main.async { [weak self] in
            self?.normalizeCloseWindowShortcut()
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isTerminationReplyPending else { return .terminateLater }
        guard let runtime else { return .terminateNow }

        let activeCount = runtime.activeDownloadCount
        if activeCount > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = BrowserLocalization.string("active_downloads")
            alert.informativeText = BrowserLocalization.string(
                "active_downloads_info",
                activeCount
            )
            alert.addButton(withTitle: BrowserLocalization.string("resume_downloads"))
            alert.addButton(withTitle: BrowserLocalization.string("quit"))
            guard alert.runModal() != .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }

        isTerminationReplyPending = true
        Task { @MainActor [weak self] in
            await runtime.prepareForTermination()
            await AIChatStore.shared.flush()
            await AIMemoryStore.shared.flush()
            self?.isTerminationReplyPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func normalizeCloseWindowShortcut(in menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }

        for item in menu.items {
            if item.action == #selector(NSWindow.performClose(_:)) {
                item.keyEquivalent = "w"
                item.keyEquivalentModifierMask = [.control]
            }
            normalizeCloseWindowShortcut(in: item.submenu)
        }
    }
}
