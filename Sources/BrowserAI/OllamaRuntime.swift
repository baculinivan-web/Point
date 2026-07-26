import AppKit
import BrowserCore
import Foundation
import Observation

/// Detects, installs, launches, and provisions a local Ollama runtime.
///
/// The app is sandboxed, so a silent system-wide install is not possible.
/// Instead the runtime downloads the official app bundle into the app's own
/// container, launches it from there (Ollama then offers to move itself to
/// /Applications), and provisions models over the local HTTP API.
@MainActor
@Observable
public final class OllamaRuntime {
    public static let shared = OllamaRuntime()

    public static let serverBaseURL = URL(string: "http://127.0.0.1:11434")!
    public static var openAICompatibleBaseURL: URL {
        serverBaseURL.appending(path: "v1")
    }

    private static let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    public static let recommendedModel = "qwen3:8b"

    public enum Status: Equatable, Sendable {
        case unknown
        case checking
        case notInstalled
        case installedNotRunning
        case running
    }

    public enum InstallPhase: Equatable, Sendable {
        case idle
        case downloading(progress: Double?)
        case extracting
        case launching
        case waitingForServer
        case failed(String)
    }

    public private(set) var status: Status = .unknown
    public private(set) var installPhase: InstallPhase = .idle
    public private(set) var availableModels: [String] = []
    public private(set) var pullProgress: (model: String, fraction: Double?)?
    public private(set) var pullError: String?

    private var refreshTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?

    private init() {}

    public var isBusy: Bool {
        if case .idle = installPhase, pullProgress == nil { return false }
        if case .failed = installPhase, pullProgress == nil { return false }
        return true
    }

    // MARK: - Detection

    public func refresh() {
        guard refreshTask == nil else { return }
        status = status == .unknown ? .checking : status
        refreshTask = Task { @MainActor [weak self] in
            defer { self?.refreshTask = nil }
            guard let self else { return }
            if let models = await Self.fetchInstalledModels() {
                status = .running
                availableModels = models
                return
            }
            availableModels = []
            status = Self.locateInstalledApp() == nil ? .notInstalled : .installedNotRunning
        }
    }

    private static func fetchInstalledModels() async -> [String]? {
        var request = URLRequest(url: serverBaseURL.appending(path: "api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(AIJSONValue.self, from: data),
              case let .array(models)? = payload["models"]
        else { return nil }
        return models.compactMap { $0["name"]?.stringValue }.sorted()
    }

    private static func locateInstalledApp() -> URL? {
        var candidates = [
            URL(fileURLWithPath: "/Applications/Ollama.app")
        ]
        candidates.append(containerAppURL)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var containerAppURL: URL {
        supportDirectory.appending(path: "Ollama.app", directoryHint: .isDirectory)
    }

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Point/Ollama", directoryHint: .isDirectory)
    }

    // MARK: - Install & launch

    /// Downloads the official Ollama app into the container, launches it, and
    /// waits for the local server to come up.
    public func installAndLaunch() {
        guard installTask == nil else { return }
        installPhase = .downloading(progress: nil)
        installTask = Task { @MainActor [weak self] in
            defer { self?.installTask = nil }
            guard let self else { return }
            do {
                let appURL: URL
                if let existing = Self.locateInstalledApp() {
                    appURL = existing
                } else {
                    let archiveURL = try await downloadArchive()
                    installPhase = .extracting
                    appURL = try await Self.extractApp(from: archiveURL)
                }
                installPhase = .launching
                try await Self.launchApp(at: appURL)
                installPhase = .waitingForServer
                let cameUp = await Self.waitForServer(timeout: 120)
                installPhase = cameUp
                    ? .idle
                    : .failed(BrowserLocalization.string("ollama_server_not_reachable"))
                refresh()
                if cameUp, availableModels.isEmpty {
                    pullModel(Self.recommendedModel)
                }
            } catch is CancellationError {
                installPhase = .idle
            } catch {
                installPhase = .failed(error.localizedDescription)
            }
        }
    }

    public func launchInstalled() {
        installAndLaunch()
    }

    private func downloadArchive() async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: Self.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIProviderError.invalidResponse
        }
        let expectedLength = http.expectedContentLength

        let directory = Self.supportDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let archiveURL = directory.appending(path: "Ollama-darwin.zip")
        FileManager.default.createFile(atPath: archiveURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archiveURL)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expectedLength > 0 {
                    installPhase = .downloading(
                        progress: Double(received) / Double(expectedLength)
                    )
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        return archiveURL
    }

    private static func extractApp(from archiveURL: URL) async throws -> URL {
        let destination = supportDirectory
        try? FileManager.default.removeItem(at: containerAppURL)
        try await runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", archiveURL.path, destination.path]
        )
        try? FileManager.default.removeItem(at: archiveURL)
        guard FileManager.default.fileExists(atPath: containerAppURL.path) else {
            throw AIProviderError.invalidResponse
        }
        return containerAppURL
    }

    private static func runProcess(executable: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (
            continuation: CheckedContinuation<Void, any Error>
        ) in
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AIProviderError.network(
                        "\(executable) exited with \(finished.terminationStatus)"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func launchApp(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func waitForServer(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await fetchInstalledModels() != nil { return true }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return false }
        }
        return false
    }

    // MARK: - Models

    /// Pulls a model through the local API, streaming NDJSON progress lines.
    public func pullModel(_ model: String) {
        guard pullTask == nil, !model.isEmpty else { return }
        pullError = nil
        pullProgress = (model: model, fraction: nil)
        pullTask = Task { @MainActor [weak self] in
            defer {
                self?.pullTask = nil
                self?.pullProgress = nil
            }
            guard let self else { return }
            do {
                var request = URLRequest(
                    url: Self.serverBaseURL.appending(path: "api/pull")
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: ["name": model, "stream": true]
                )
                let session = AIProviderHTTP.makeSession()
                defer { session.invalidateAndCancel() }
                let bytes = try await AIProviderHTTP.openStream(request, session: session)
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard let data = line.data(using: .utf8),
                          let payload = try? JSONDecoder().decode(
                              AIJSONValue.self,
                              from: data
                          )
                    else { continue }
                    if let message = payload["error"]?.stringValue {
                        throw AIProviderError.network(message)
                    }
                    if case let .number(total)? = payload["total"],
                       case let .number(completed)? = payload["completed"],
                       total > 0 {
                        pullProgress = (model: model, fraction: completed / total)
                    }
                }
                if AIChatSettings.shared.ollamaModel.isEmpty {
                    AIChatSettings.shared.ollamaModel = model
                }
                refresh()
            } catch is CancellationError {
                // Cancelled pulls simply stop; Ollama resumes on the next attempt.
            } catch {
                pullError = error.localizedDescription
            }
        }
    }

    public func cancelPull() {
        pullTask?.cancel()
    }
}
