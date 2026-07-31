import AppKit
import BrowserAI
import BrowserCore
import BrowserEngine
import BrowserPersistence
import BrowserUI
import Observation
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
    let manualUpdateCoordinator: ManualUpdateCoordinator

    private let persistenceController: BrowserPersistenceController?
    private let browsingHistoryRepository: any BrowsingHistoryRepository
    private lazy var maintenance = BrowsingDataMaintenance(
        browsingHistoryRepository: browsingHistoryRepository
    )
    private var privateDownloadManagers: [WeakDownloadManager] = []
    private var standardWindowCount = 0
    private var hasClaimedOnboarding = false

    init() {
        downloadManager = DownloadManager(
            historyRepository: FileDownloadHistoryRepository()
        )
        manualUpdateCoordinator = ManualUpdateCoordinator()
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

    func startManualUpdateChecks() async {
        await manualUpdateCoordinator.start()
    }

    func checkForUpdatesFromSettings() async -> BrowserManualUpdate.CheckStatus {
        await manualUpdateCoordinator.checkFromSettings()
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
            isOnboardingPresented: $isOnboardingPresented,
            availableUpdate: isPrivate
                ? nil
                : runtime.manualUpdateCoordinator.availableRelease,
            onInstallUpdate: { release in
                runtime.manualUpdateCoordinator.beginDownload(release)
            }
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
                    await runtime.startManualUpdateChecks()
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
            .onReceive(
                NotificationCenter.default.publisher(
                    for: BrowserManualUpdate.checkRequested
                )
            ) { _ in
                guard !isPrivate else { return }
                Task {
                    let status = await runtime.checkForUpdatesFromSettings()
                    NotificationCenter.default.post(
                        name: BrowserManualUpdate.checkFinished,
                        object: nil,
                        userInfo: [
                            BrowserManualUpdate.statusUserInfoKey: status.rawValue
                        ]
                    )
                }
            }
            .manualUpdateAlerts(
                coordinator: runtime.manualUpdateCoordinator,
                isEnabled: !isPrivate
            )
    }
}

@MainActor
@Observable
private final class ManualUpdateCoordinator {
    private static let lastCheckKey = "ManualUpdateLastCheck"
    private static let lastPromptedVersionKey = "ManualUpdateLastPromptedVersion"
    private static let lastInstalledVersionKey = "ManualUpdateLastInstalledVersion"
    private static let lastNotesVersionKey = "ManualUpdateLastNotesVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let configuration: ReleaseUpdateConfiguration
    private let service: ReleaseUpdateService
    private let defaults: UserDefaults
    private var isChecking = false
    private var scheduledCheckTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    private(set) var availableRelease: AvailableRelease?
    private(set) var isUpdatePromptPresented = false
    private(set) var isDownloading = false
    private(set) var isInstallationInstructionsPresented = false
    private(set) var downloadErrorMessage: String?

    init(
        configuration: ReleaseUpdateConfiguration = .appBundle,
        defaults: UserDefaults = .standard
    ) {
        self.configuration = configuration
        self.service = ReleaseUpdateService(configuration: configuration)
        self.defaults = defaults
    }

    func start() async {
        openNotesAfterVersionChangeIfNeeded()
        _ = await checkForUpdateIfNeeded()
        guard scheduledCheckTask == nil else { return }
        scheduledCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.checkInterval))
                guard !Task.isCancelled, let self else { return }
                _ = await self.checkForUpdateIfNeeded()
            }
        }
    }

    func checkFromSettings() async -> BrowserManualUpdate.CheckStatus {
        await checkForUpdateIfNeeded(force: true)
    }

    func openReleaseNotes(for release: AvailableRelease) {
        guard let url = configuration.releaseNotesURL(for: release.version) else { return }
        NSWorkspace.shared.open(url)
    }

    func dismissUpdatePrompt() {
        isUpdatePromptPresented = false
    }

    func dismissInstallationInstructions() {
        isInstallationInstructionsPresented = false
    }

    func dismissDownloadError() {
        downloadErrorMessage = nil
    }

    func beginDownload(_ release: AvailableRelease) {
        guard downloadTask == nil else { return }
        downloadTask = Task { @MainActor [weak self] in
            await self?.download(release)
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func download(_ release: AvailableRelease) async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadErrorMessage = nil
        defer {
            isDownloading = false
            downloadTask = nil
        }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(
                from: release.asset.downloadURL
            )
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode)
            else {
                throw URLError(.badServerResponse)
            }
            let downloadedURL = try moveDownloadToDownloadsFolder(
                temporaryURL,
                filename: release.asset.name
            )
            NSWorkspace.shared.activateFileViewerSelecting([downloadedURL])
            isInstallationInstructionsPresented = true
        } catch is CancellationError {
            // A cancelled download is intentional and should not create a
            // persistent or repeated error prompt.
        } catch {
            downloadErrorMessage = BrowserLocalization.string("update_download_failed")
        }
    }

    private func checkForUpdateIfNeeded(
        now: Date = Date(),
        force: Bool = false
    ) async -> BrowserManualUpdate.CheckStatus {
        guard configuration.isConfigured else {
            return .configurationMissing
        }
        guard !isChecking else { return .checkInProgress }
        let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard force || lastCheck.map({
            now.timeIntervalSince($0) >= Self.checkInterval
        }) ?? true else {
            return availableRelease == nil ? .checkedRecently : .updateAvailable
        }

        // Record every attempt before starting network work. This keeps a
        // transient offline or malformed-response state from being retried on
        // every new window during the same 24-hour period.
        defaults.set(now, forKey: Self.lastCheckKey)
        isChecking = true
        defer { isChecking = false }

        guard let installedVersion = installedVersion else { return .unavailable }
        do {
            guard let release = try await service.latestUpdate(
                installedVersion: installedVersion
            ) else { return .upToDate }
            let version = release.version.description
            // Keep the sidebar entry available on every launch, even after a
            // person has already dismissed the one-time native prompt.
            availableRelease = release
            guard defaults.string(forKey: Self.lastPromptedVersionKey) != version else {
                return .updateAvailable
            }
            defaults.set(version, forKey: Self.lastPromptedVersionKey)
            isUpdatePromptPresented = true
            return .updateAvailable
        } catch {
            // Network, JSON, and missing-asset failures intentionally stay
            // quiet; the next eligible daily check can recover automatically.
            return .unavailable
        }
    }

    private var installedVersion: ReleaseVersion? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return nil
        }
        return ReleaseVersion(value)
    }

    private func openNotesAfterVersionChangeIfNeeded() {
        guard let installedVersion else { return }
        let version = installedVersion.description
        defer { defaults.set(version, forKey: Self.lastInstalledVersionKey) }
        guard let previousVersion = defaults.string(
            forKey: Self.lastInstalledVersionKey
        ), previousVersion != version,
           defaults.string(forKey: Self.lastNotesVersionKey) != version,
           let notesURL = configuration.releaseNotesURL(for: installedVersion)
        else {
            return
        }
        defaults.set(version, forKey: Self.lastNotesVersionKey)
        NSWorkspace.shared.open(notesURL)
    }

    private func moveDownloadToDownloadsFolder(
        _ temporaryURL: URL,
        filename: String
    ) throws -> URL {
        let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let destination = uniqueDownloadURL(
            in: downloadsDirectory,
            preferredFilename: filename
        )
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func uniqueDownloadURL(
        in directory: URL,
        preferredFilename: String
    ) -> URL {
        let original = directory.appending(path: preferredFilename)
        guard FileManager.default.fileExists(atPath: original.path) else {
            return original
        }
        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var suffix = 2
        while true {
            let candidate = directory.appending(
                path: "\(base) \(suffix)"
            ).appendingPathExtension(ext)
            guard !FileManager.default.fileExists(atPath: candidate.path) else {
                suffix += 1
                continue
            }
            return candidate
        }
    }
}

private extension View {
    @ViewBuilder
    func manualUpdateAlerts(
        coordinator: ManualUpdateCoordinator,
        isEnabled: Bool
    ) -> some View {
        if isEnabled {
            modifier(ManualUpdateAlertModifier(coordinator: coordinator))
        } else {
            self
        }
    }
}

private struct ManualUpdateAlertModifier: ViewModifier {
    let coordinator: ManualUpdateCoordinator

    func body(content: Content) -> some View {
        content
            .alert(
                BrowserLocalization.string("update_available_title"),
                isPresented: Binding(
                    get: { coordinator.isUpdatePromptPresented },
                    set: { if !$0 { coordinator.dismissUpdatePrompt() } }
                ),
                presenting: coordinator.availableRelease
            ) { release in
                Button(BrowserLocalization.string("update")) {
                    coordinator.beginDownload(release)
                }
                Button(BrowserLocalization.string("whats_new")) {
                    coordinator.openReleaseNotes(for: release)
                }
                Button(BrowserLocalization.string("later"), role: .cancel) {}
            } message: { release in
                Text(BrowserLocalization.string(
                    "update_available_message",
                    release.version.description
                ))
            }
            .alert(
                BrowserLocalization.string("update_ready_title"),
                isPresented: Binding(
                    get: { coordinator.isInstallationInstructionsPresented },
                    set: { if !$0 { coordinator.dismissInstallationInstructions() } }
                )
            ) {
                Button(BrowserLocalization.string("done"), role: .cancel) {}
            } message: {
                Text(BrowserLocalization.string("update_ready_instructions"))
            }
            .alert(
                BrowserLocalization.string("update_downloading_title"),
                isPresented: Binding(
                    get: { coordinator.isDownloading },
                    set: { if !$0 { coordinator.cancelDownload() } }
                )
            ) {
                Button(BrowserLocalization.string("cancel"), role: .cancel) {
                    coordinator.cancelDownload()
                }
            } message: {
                Text(BrowserLocalization.string("update_downloading_message"))
            }
            .alert(
                BrowserLocalization.string("update_download_failed_title"),
                isPresented: Binding(
                    get: { coordinator.downloadErrorMessage != nil },
                    set: { if !$0 { coordinator.dismissDownloadError() } }
                )
            ) {
                Button(BrowserLocalization.string("done"), role: .cancel) {}
            } message: {
                Text(coordinator.downloadErrorMessage ?? "")
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
            await AIChatStore.shared.flush()
            await AIMemoryStore.shared.flush()
            self?.isTerminationReplyPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
