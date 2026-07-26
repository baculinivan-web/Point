import BrowserCore
import Foundation

/// Runs short Python scripts the model writes.
///
/// The process inherits the app sandbox, so it can only touch this scratch
/// directory and whatever the app's entitlements already allow. A timeout and
/// an output cap keep a runaway script from hanging the chat.
enum PythonToolRunner {
    private static let timeout: TimeInterval = 15
    private static let probeTimeout: TimeInterval = 5
    private static let outputLimit = 12000

    enum Failure: LocalizedError {
        case interpreterMissing

        var errorDescription: String? {
            BrowserLocalization.string("ai_python_missing")
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

        let result = await execute(
            interpreter: interpreter,
            arguments: [scriptURL.path],
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        return format(result)
    }

    // MARK: - Process execution

    private struct ProcessResult {
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 0
        var timedOut = false
        var launchError: String?
    }

    /// Collects pipe output as it arrives, from the reader callbacks.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var standardOutput = Data()
        private var standardError = Data()

        func appendOutput(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); standardOutput.append(data); lock.unlock()
        }

        func appendError(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); standardError.append(data); lock.unlock()
        }

        var text: (out: String, err: String) {
            lock.lock()
            defer { lock.unlock() }
            return (
                String(decoding: standardOutput, as: UTF8.self),
                String(decoding: standardError, as: UTF8.self)
            )
        }
    }

    private static func execute(
        interpreter: URL,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = interpreter
                process.arguments = arguments
                if let workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }
                process.environment = [
                    // Unbuffered output means a timeout still yields results.
                    "PYTHONUNBUFFERED": "1",
                    "HOME": workingDirectory?.path ?? NSTemporaryDirectory(),
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
                ]

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                // Without this, a script that calls input() inherits the app's
                // stdin and blocks forever.
                process.standardInput = FileHandle.nullDevice

                // Reading both pipes as data arrives avoids the classic
                // deadlock where a full stderr buffer stops the process from
                // ever closing stdout.
                let buffer = OutputBuffer()
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    buffer.appendOutput(handle.availableData)
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    buffer.appendError(handle.availableData)
                }

                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        returning: ProcessResult(launchError: error.localizedDescription)
                    )
                    return
                }

                var timedOut = false
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    timedOut = true
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut {
                        kill(process.processIdentifier, SIGKILL)
                        _ = finished.wait(timeout: .now() + 2)
                    }
                }

                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                buffer.appendOutput(outPipe.fileHandleForReading.availableData)
                buffer.appendError(errPipe.fileHandleForReading.availableData)

                let text = buffer.text
                continuation.resume(
                    returning: ProcessResult(
                        stdout: text.out,
                        stderr: text.err,
                        exitCode: process.terminationStatus,
                        timedOut: timedOut
                    )
                )
            }
        }
    }

    private static func format(_ result: ProcessResult) -> String {
        if let launchError = result.launchError {
            return "Failed to start Python: \(launchError)"
        }

        var parts: [String] = []
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { parts.append("stdout:\n\(String(out.prefix(outputLimit)))") }
        if !err.isEmpty { parts.append("stderr:\n\(String(err.prefix(outputLimit)))") }
        if result.timedOut {
            // Partial output is more useful to the model than a bare failure.
            parts.append(BrowserLocalization.string("ai_python_timeout", Int(timeout)))
        } else if result.exitCode != 0 {
            parts.append("exit code: \(result.exitCode)")
        }
        if parts.isEmpty { parts.append("The script produced no output.") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Interpreter discovery

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
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            let result = await execute(
                interpreter: url,
                arguments: ["-c", "print('ok')"],
                workingDirectory: nil,
                timeout: probeTimeout
            )
            guard result.launchError == nil,
                  !result.timedOut,
                  result.exitCode == 0,
                  result.stdout.contains("ok")
            else { continue }
            await MainActor.run { cachedInterpreter = url }
            return url
        }
        return nil
    }
}
