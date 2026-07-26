import BrowserCore
import Foundation

/// Runs short Python scripts the model writes.
///
/// The process inherits the app sandbox, so it can only touch this scratch
/// directory and whatever the app's entitlements already allow. A timeout and
/// an output cap keep a runaway script from hanging the chat.
enum PythonToolRunner {
    private static let timeout: TimeInterval = 20
    private static let outputLimit = 12000

    enum Failure: LocalizedError {
        case interpreterMissing
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .interpreterMissing:
                BrowserLocalization.string("ai_python_missing")
            case let .timedOut(seconds):
                BrowserLocalization.string("ai_python_timeout", Int(seconds))
            }
        }
    }

    static func run(code: String) async throws -> String {
        guard let interpreter = await resolveInterpreter() else {
            throw Failure.interpreterMissing
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "python-tool-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let scriptURL = workingDirectory.appending(path: "script.py")
        try Data(code.utf8).write(to: scriptURL)

        let process = Process()
        process.executableURL = interpreter
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = workingDirectory
        process.environment = [
            // Unbuffered output means a timeout still yields partial results.
            "PYTHONUNBUFFERED": "1",
            "HOME": workingDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        ]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()

        let collector = Task.detached(priority: .utility) {
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = errors.fileHandleForReading.readDataToEndOfFile()
            return (out, err)
        }

        let watchdog = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, process.isRunning else { return false }
            process.terminate()
            try? await Task.sleep(for: .milliseconds(300))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return true
        }

        let (outData, errData) = await collector.value
        process.waitUntilExit()
        let didTimeOut = await watchdog.value
        watchdog.cancel()

        if didTimeOut { throw Failure.timedOut(timeout) }

        return format(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    private static func format(
        stdout: String,
        stderr: String,
        exitCode: Int32
    ) -> String {
        var parts: [String] = []
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { parts.append("stdout:\n\(String(out.prefix(outputLimit)))") }
        if !err.isEmpty { parts.append("stderr:\n\(String(err.prefix(outputLimit)))") }
        if exitCode != 0 { parts.append("exit code: \(exitCode)") }
        if parts.isEmpty { parts.append("The script produced no output.") }
        return parts.joined(separator: "\n\n")
    }

    /// Interpreters in preference order.
    ///
    /// `/usr/bin/python3` is deliberately last: it is a shim that forwards to
    /// `xcrun`, and `xcrun` refuses to run inside an App Sandbox
    /// ("cannot be used within an App Sandbox"). The real interpreters below
    /// are ordinary binaries and run fine under the sandbox.
    private static let candidatePaths = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/Library/Developer/CommandLineTools/usr/bin/python3",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
        "/usr/bin/python3"
    ]

    /// Caches the probe result so repeated tool calls do not re-test binaries.
    @MainActor
    private static var cachedInterpreter: URL?

    /// Probes candidates once and remembers the first that actually runs, so a
    /// shim that only fails at execution time is skipped rather than trusted.
    private static func resolveInterpreter() async -> URL? {
        if let cached = await MainActor.run(body: { cachedInterpreter }) {
            return cached
        }
        for path in candidatePaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard await probe(url) else { continue }
            await MainActor.run { cachedInterpreter = url }
            return url
        }
        return nil
    }

    private static func probe(_ interpreter: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = interpreter
            process.arguments = ["-c", "print('ok')"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.environment = ["PATH": "/usr/bin:/bin"]
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}
