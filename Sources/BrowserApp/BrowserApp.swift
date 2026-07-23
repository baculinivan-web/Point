import AppKit
import BrowserCore
import BrowserEngine
import BrowserPersistence
import BrowserUI
import SwiftUI
import WebKit

private enum BrowserSceneID {
    static let standard = "browser-window"
    static let privateBrowsing = "private-browser-window"
}

@main
@MainActor
struct BrowserApp: App {
    @NSApplicationDelegateAdaptor(BrowserApplicationDelegate.self)
    private var applicationDelegate
    private let runtime: BrowserRuntime

    init() {
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
    }
}

@MainActor
private final class BrowserRuntime {
    let downloadManager: DownloadManager

    private let persistenceController: BrowserPersistenceController?
    private let browsingHistoryRepository: any BrowsingHistoryRepository
    private lazy var maintenance = BrowsingDataMaintenance(
        browsingHistoryRepository: browsingHistoryRepository
    )
    private var privateDownloadManagers: [WeakDownloadManager] = []
    private var standardWindowCount = 0

    init() {
        downloadManager = DownloadManager(
            historyRepository: FileDownloadHistoryRepository()
        )
        let controller = try? BrowserPersistenceController()
        persistenceController = controller
        browsingHistoryRepository = controller?.browsingHistoryRepository()
            ?? FileBrowsingHistoryRepository()
    }

    func makeWindowModel(isPrivate: Bool) -> BrowserWindowModel {
        if isPrivate {
            let privateDownloadManager = DownloadManager()
            privateDownloadManagers.removeAll { $0.value == nil }
            privateDownloadManagers.append(
                WeakDownloadManager(privateDownloadManager)
            )
            return BrowserWindowModel(
                repository: InMemorySessionRepository(),
                sitePermissionRepository: InMemorySitePermissionRepository(),
                browsingHistoryRepository: InMemoryBrowsingHistoryRepository(),
                downloadManager: privateDownloadManager,
                faviconRepository: FaviconRepository(persistsToDisk: false),
                isPrivate: true,
                websiteDataStore: .nonPersistent()
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

        return BrowserWindowModel(
            repository: sessionRepository,
            sitePermissionRepository: FileSitePermissionRepository(),
            browsingHistoryRepository: browsingHistoryRepository,
            downloadManager: downloadManager,
            isPrivate: false,
            websiteDataStore: .default()
        )
    }

    func performMaintenanceIfNeeded() async {
        await maintenance.start()
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

private struct BrowserWindowScene: View {
    @Environment(\.openWindow) private var openWindow
    @State private var model: BrowserWindowModel
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
        BrowserWindowView(model: model)
            .task {
                model.openWindowRequest = { shouldOpenPrivateWindow in
                    openWindow(
                        id: shouldOpenPrivateWindow
                            ? BrowserSceneID.privateBrowsing
                            : BrowserSceneID.standard
                    )
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
            await runtime.downloadManager.flushHistory()
            self?.isTerminationReplyPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
