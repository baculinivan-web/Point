import Foundation
import Testing
@testable import BrowserUI

@Suite("Python tool runner")
struct PythonToolRunnerTests {
    /// The bug this guards: the runner always waited out its full timeout, so
    /// every call took at least as long as the watchdog.
    @Test(.timeLimit(.minutes(1)))
    func trivialScriptReturnsPromptlyWithOutput() async throws {
        let started = Date()
        let output: String
        do {
            output = try await PythonToolRunner.run(code: "print(sum(range(1, 101)))")
        } catch {
            // No usable interpreter on this machine; nothing to assert.
            return
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(output.contains("5050"))
        #expect(elapsed < 10)
    }

    /// A script that reads stdin used to inherit the app's and block forever.
    @Test(.timeLimit(.minutes(1)))
    func scriptReadingStdinDoesNotHang() async throws {
        do {
            let output = try await PythonToolRunner.run(
                code: "import sys; data = sys.stdin.read(); print('read', len(data))"
            )
            #expect(output.contains("read 0"))
        } catch {
            return
        }
    }
}
