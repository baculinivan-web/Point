import AppKit
import BrowserCore
import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class DownloadManager: NSObject, WKDownloadDelegate, NSOpenSavePanelDelegate {
    public private(set) var items: [DownloadItem] = []

    private let historyRepository: (any DownloadHistoryRepository)?
    @ObservationIgnored private var native: [UUID: InstallerDownload] = [:]
    @ObservationIgnored private var pendingNative: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var active: [ObjectIdentifier: ActiveDownload] = [:]
    @ObservationIgnored private var historyPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var didRestoreHistory = false

    public init(historyRepository: (any DownloadHistoryRepository)? = nil) {
        self.historyRepository = historyRepository
        super.init()
    }

    public var activeDownloadCount: Int {
        active.count + native.count + pendingNative.count
    }

    public func flushHistory() async {
        await historyPersistenceTask?.value
    }

    public func restoreHistory() async {
        guard !didRestoreHistory else { return }
        didRestoreHistory = true
        guard let historyRepository else { return }
        guard let records = try? await historyRepository.load() else { return }

        let activeItems = items.filter(\.state.isActive)
        let activeIDs = Set(activeItems.map(\.id))
        let restoredItems = records.prefix(200).compactMap { record -> DownloadItem? in
            guard !activeIDs.contains(record.id) else { return nil }
            let state: DownloadState = switch record.state {
            case .finished:
                .finished
            case .cancelled:
                .cancelled
            case .failed:
                .failed(BrowserLocalization.string("download_failed"))
            }
            return DownloadItem(
                id: record.id,
                sourceURL: nil,
                suggestedFilename: record.suggestedFilename,
                destinationURL: record.destinationURL,
                state: state,
                fractionCompleted: record.state == .finished ? 1 : nil,
                resumeData: nil,
                completedAt: record.completedAt
            )
        }
        items = activeItems + restoredItems
    }

    public func begin(_ download: WKDownload) {
        register(
            download,
            item: DownloadItem(
                sourceURL: download.originalRequest?.url,
                suggestedFilename: "download"
            )
        )
    }

    public func clearInactive() {
        items.removeAll { !$0.state.isActive }
        persistHistory()
    }

    public func remove(_ id: UUID) {
        guard items.first(where: { $0.id == id })?.state.isActive == false else { return }
        items.removeAll { $0.id == id }
        persistHistory()
    }

    private func register(_ download: WKDownload, item: DownloadItem) {
        let key = ObjectIdentifier(download)
        guard active[key] == nil else { return }

        let itemID = item.id
        let observation = download.progress.observe(
            \Progress.fractionCompleted,
            options: [.initial, .new]
        ) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in
                self?.update(itemID) { item in
                    item.fractionCompleted = fraction.isFinite ? fraction : nil
                }
            }
        }

        items.insert(item, at: 0)
        active[key] = ActiveDownload(
            id: itemID,
            download: download,
            progressObservation: observation
        )
        download.delegate = self
    }

    public func cancel(_ id: UUID) {
        if let pending = pendingNative.removeValue(forKey: id) {
            pending.cancel()
            update(id) { $0.state = .cancelled; $0.completedAt = Date() }
            persistHistory()
            return
        }
        if let transfer = native[id] {
            transfer.cancel()
            return
        }
        guard let record = active.values.first(where: { $0.id == id }) else { return }
        record.download.cancel { [weak self] resumeData in
            guard let self else { return }
            update(id) { item in
                item.state = .cancelled
                item.resumeData = resumeData
                item.completedAt = Date()
            }
            finish(record.download)
            persistHistory()
        }
    }

    public func resume(_ id: UUID, using webView: WKWebView) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let resumeData = items[index].resumeData
        else { return }
        var resumedItem = items[index]
        resumedItem.state = .awaitingDestination
        resumedItem.fractionCompleted = nil
        resumedItem.resumeData = nil
        resumedItem.destinationURL = nil
        resumedItem.completedAt = nil

        webView.resumeDownload(fromResumeData: resumeData) { [weak self] download in
            guard let self else { return }
            items.removeAll { $0.id == id }
            register(download, item: resumedItem)
        }
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let safeFilename = DownloadFilenameSanitizer.sanitize(suggestedFilename)
        guard let record = active[ObjectIdentifier(download)] else {
            completionHandler(nil)
            return
        }
        update(record.id) { item in
            item.suggestedFilename = safeFilename
            item.state = .awaitingDestination
        }

        // Obtain explicit user consent through the system save panel. The
        // user-selected.executable entitlement applies to this selected URL.
        let panel = NSSavePanel()
        let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first
        panel.directoryURL = downloadsDirectory
        if let downloadsDirectory {
            panel.nameFieldStringValue = DownloadDestinationResolver.availableURL(
                in: downloadsDirectory,
                suggestedFilename: safeFilename,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            ).lastPathComponent
        } else {
            panel.nameFieldStringValue = safeFilename
        }
        panel.delegate = self
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self else {
                completionHandler(nil)
                return
            }
            guard response == .OK, let destination = panel.url else {
                self.update(record.id) { item in
                    item.state = .cancelled
                    item.completedAt = Date()
                }
                completionHandler(nil)
                self.finish(download)
                self.persistHistory()
                return
            }
            self.update(record.id) { item in
                item.destinationURL = destination
                item.state = .downloading
            }
            let request = download.originalRequest
            let installerExtensions: Set<String> = ["dmg", "pkg", "zip", "xip"]
            if let request, let source = request.url,
               ["https", "http"].contains(source.scheme?.lowercased() ?? ""),
               (request.httpMethod ?? "GET") == "GET",
               installerExtensions.contains(destination.pathExtension.lowercased()) {
                let webView = download.webView
                // Detach before cancellation so WebKit cannot overwrite the new state.
                self.finish(download)
                completionHandler(nil)
                self.startInstaller(record.id, request: request,
                                    destination: destination, webView: webView)
            } else {
                completionHandler(destination)
            }
        }
    }

    private func startInstaller(_ id: UUID, request: URLRequest,
                                destination: URL, webView: WKWebView?) {
        pendingNative[id] = Task { @MainActor [weak self] in
            let cookies = await webView?.configuration.websiteDataStore.httpCookieStore.allCookies() ?? []
            guard !Task.isCancelled, let self, let source = request.url else { return }
            self.pendingNative[id] = nil
            let transfer = InstallerDownload(destination: destination, source: source) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.update(id) { $0.fractionCompleted = fraction }
                }
            } completion: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.native.removeValue(forKey: id) != nil else { return }
                    self.update(id) { item in
                        switch result {
                        case .success:
                            item.state = .finished
                            item.fractionCompleted = 1
                        case let .failure(error):
                            item.state = (error as? URLError)?.code == .cancelled
                                ? .cancelled : .failed(error.localizedDescription)
                        }
                        item.resumeData = nil
                        item.completedAt = Date()
                    }
                    self.persistHistory()
                }
            }
            self.native[id] = transfer
            transfer.start(request: request, cookies: cookies)
        }
    }

    public func panel(_ sender: Any, validate url: URL) throws {
        // WKDownload requires a destination that does not already exist.
        // Keep the panel open so the user can consent to a different filename.
        if FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists)
        }
    }

    public func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping @MainActor (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    public func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        if let record = active[ObjectIdentifier(download)] {
            update(record.id) { item in
                item.state = .finished
                item.fractionCompleted = 1
                item.resumeData = nil
                item.completedAt = Date()
            }
        }
        finish(download)
        persistHistory()
    }

    public func download(
        _ download: WKDownload,
        didFailWithError error: any Error,
        resumeData: Data?
    ) {
        if let record = active[ObjectIdentifier(download)] {
            update(record.id) { item in
                item.state = (error as? URLError)?.code == .cancelled
                    ? .cancelled
                    : .failed(error.localizedDescription)
                item.resumeData = resumeData
                item.completedAt = Date()
            }
        }
        finish(download)
        persistHistory()
    }

    private func update(_ id: UUID, mutation: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutation(&items[index])
    }

    private func finish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        active[key]?.progressObservation.invalidate()
        active[key] = nil
        download.delegate = nil
    }

    private func persistHistory() {
        guard let historyRepository else { return }
        let records = Array(
            items.compactMap(Self.historyRecord(from:)).prefix(200)
        )
        let previousSave = historyPersistenceTask
        historyPersistenceTask = Task {
            await previousSave?.value
            try? await historyRepository.save(records)
        }
    }

    private static func historyRecord(
        from item: DownloadItem
    ) -> DownloadHistoryRecord? {
        guard !item.state.isActive, let completedAt = item.completedAt else {
            return nil
        }
        let state: DownloadHistoryState
        switch item.state {
        case .finished:
            state = .finished
        case .cancelled:
            state = .cancelled
        case .failed:
            state = .failed
        case .awaitingDestination, .downloading:
            return nil
        }
        return DownloadHistoryRecord(
            id: item.id,
            suggestedFilename: item.suggestedFilename,
            destinationURL: item.destinationURL,
            state: state,
            completedAt: completedAt
        )
    }
}

@MainActor
private final class ActiveDownload {
    let id: UUID
    let download: WKDownload
    let progressObservation: NSKeyValueObservation

    init(
        id: UUID,
        download: WKDownload,
        progressObservation: NSKeyValueObservation
    ) {
        self.id = id
        self.download = download
        self.progressObservation = progressObservation
    }
}
