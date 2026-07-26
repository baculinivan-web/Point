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
        guard let interpreter = locateInterpreter() else {
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
        // -u keeps output unbuffered so a timeout still yields partial output.
        process.environment = ["PYTHONUNBUFFERED": "1", "HOME": workingDirectory.path]

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

    private static func locateInterpreter() -> URL? {
        // /usr/bin/python3 is a stub that fails without Command Line Tools, so
        // check that it actually runs before handing it a script.
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
