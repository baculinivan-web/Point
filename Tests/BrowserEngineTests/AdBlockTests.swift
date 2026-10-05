@testable import BrowserEngine
import Foundation
@preconcurrency import Network
import Testing
import WebKit

@Suite("WebKit ad blocking", .serialized)
@MainActor
struct AdBlockTests {
    @Test("Blocking defaults to on and persists when disabled")
    func preferencePersists() throws {
        let name = "AdBlockTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let blocker = AdBlockController(defaults: defaults)
        #expect(blocker.isEnabled)
        blocker.isEnabled = false
        #expect(!AdBlockController(defaults: defaults).isEnabled)
    }

    @Test("Bundled filters block ad requests, preserve content, and can be switched off")
    func filtersWorkInWebKit() async throws {
        let name = "AdBlockTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let blocker = AdBlockController(defaults: defaults)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let fixture = try AdBlockFixture()
        let port = try await fixture.start()
        defer { fixture.listener.cancel() }
        let view = WKWebView(frame: .zero, configuration: configuration)
        let controller = view.configuration.userContentController
        blocker.register(controller)
        await blocker.prepare(controller)
        #expect(!blocker.hasFailed)

        // A trailing dot keeps the fixture outside the filters' explicit
        // localhost / 127.0.0.1 cosmetic-filtering exemptions.
        let url = try #require(URL(string: "http://localhost.:\(port)/page"))
        view.load(URLRequest(url: url))
        let blocked = try await result(in: view)
        #expect(blocked["normal"] as? Bool == true)
        #expect(blocked["ad"] as? Bool == false)
        #expect(blocked["display"] as? String == "none")

        blocker.isEnabled = false
        view.load(URLRequest(url: url))
        let unblocked = try await result(in: view)
        #expect(unblocked["normal"] as? Bool == true)
        #expect(unblocked["ad"] as? Bool == true)
        #expect(unblocked["display"] as? String != "none")

        blocker.isEnabled = true
        view.load(URLRequest(url: url))
        let reenabled = try await result(in: view)
        #expect(reenabled["ad"] as? Bool == false)
    }

    private func result(in view: WKWebView) async throws -> [String: Any] {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if !view.isLoading,
               let result = try? await view.evaluateJavaScript("""
               document.readyState === 'complete' && document.getElementById('banner') ?
               ({normal: !!window.normalLoaded, ad: !!window.adLoaded,
                 display: getComputedStyle(document.getElementById('banner')).display}) : null
               """) as? [String: Any] {
                return result
            }
        }
        throw CocoaError(.fileReadUnknown)
    }
}

@MainActor
private final class AdBlockFixture {
    let listener: NWListener

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let response = Self.response(for: path)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    continuation.resume(returning: listener.port!.rawValue)
                    listener.stateUpdateHandler = nil
                case .failed(let error):
                    continuation.resume(throwing: error)
                    listener.stateUpdateHandler = nil
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }

    nonisolated private static func response(for path: String) -> Data {
        let body: String
        let mime: String
        if path == "/page" {
            mime = "text/html"
            body = """
            <!doctype html><html><body>
            <div id="banner" class="adsbygoogle-wrapper">Advertisement</div>
            <p>Normal page content</p>
            <script src="/normal.js"></script>
            <script src="/banner.go?spaceid=1"></script>
            </body></html>
            """
        } else {
            mime = "application/javascript"
            body = path.hasPrefix("/banner.go") ? "window.adLoaded = true;" : "window.normalLoaded = true;"
        }
        let data = Data(body.utf8)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: \(mime); charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + data
    }
}
