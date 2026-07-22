import AppKit
import BrowserEngine
import BrowserPersistence
import BrowserUI
import SwiftUI

@main
@MainActor
struct BrowserApp: App {
    @NSApplicationDelegateAdaptor(BrowserApplicationDelegate.self)
    private var applicationDelegate
    private let downloadManager: DownloadManager
    private let browsingHistoryRepository: FileBrowsingHistoryRepository

    init() {
        let downloadManager = DownloadManager(
            historyRepository: FileDownloadHistoryRepository()
        )
        self.downloadManager = downloadManager
        browsingHistoryRepository = FileBrowsingHistoryRepository()
        applicationDelegate.downloadManager = downloadManager
    }

    var body: some Scene {
        WindowGroup {
            BrowserWindowScene(
                downloadManager: downloadManager,
                browsingHistoryRepository: browsingHistoryRepository
            )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            BrowserCommands()
        }
    }
}

private struct BrowserWindowScene: View {
    @State private var model: BrowserWindowModel

    init(
        downloadManager: DownloadManager,
        browsingHistoryRepository: FileBrowsingHistoryRepository
    ) {
        _model = State(
            initialValue: BrowserWindowModel(
                repository: FileSessionRepository(),
                sitePermissionRepository: FileSitePermissionRepository(),
                browsingHistoryRepository: browsingHistoryRepository,
                downloadManager: downloadManager
            )
        )
    }

    var body: some View {
        BrowserWindowView(model: model)
            .task {
                await model.restoreSession()
            }
            .onOpenURL { url in
                model.openExternalURL(url)
            }
    }
}

@MainActor
private final class BrowserApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var downloadManager: DownloadManager?
    private var isTerminationReplyPending = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isTerminationReplyPending else { return .terminateLater }
        guard let downloadManager else { return .terminateNow }

        let activeCount = downloadManager.activeDownloadCount
        if activeCount > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Есть активные загрузки"
            alert.informativeText = "При выходе из Browser \(activeCount) активных загрузок будут прерваны."
            alert.addButton(withTitle: "Продолжить загрузки")
            alert.addButton(withTitle: "Выйти")
            guard alert.runModal() != .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }

        isTerminationReplyPending = true
        Task { @MainActor [weak self] in
            await downloadManager.flushHistory()
            self?.isTerminationReplyPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
