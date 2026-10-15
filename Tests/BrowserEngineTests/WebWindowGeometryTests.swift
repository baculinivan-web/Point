import AppKit
import BrowserCore
import BrowserEngine
import Testing
import WebKit

@Suite("Web window geometry", .serialized)
@MainActor
struct WebWindowGeometryTests {
    @Test func pageReceivesWindowDimensionsAndRetinaScale() async throws {
        let engine = WebEngineSession(tabID: TabID())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = engine.webView
        defer { window.contentView = nil; window.close() }
        engine.webView.loadHTMLString("<html><body>Geometry</body></html>", baseURL: nil)
        var geometry: [String: Double] = [:]
        for _ in 0..<100 {
            if let result = try? await engine.webView.evaluateJavaScript("document.readyState === 'complete' ? {width: outerWidth, height: outerHeight, ratio: devicePixelRatio} : null") as? [String: Double] {
                geometry = result
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(geometry["width"] == Double(window.frame.width))
        #expect(geometry["height"] == Double(window.frame.height))
        #expect(geometry["ratio"] == Double(window.backingScaleFactor))
        window.setContentSize(NSSize(width: 960, height: 720))
        // Window geometry is sent asynchronously to WebKit's content process.
        var resized: [String: Double]?
        for _ in 0..<100 {
            resized = try await engine.webView.evaluateJavaScript("({width: outerWidth, height: outerHeight})") as? [String: Double]
            if resized?["width"] == Double(window.frame.width),
               resized?["height"] == Double(window.frame.height) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(resized?["width"] == Double(window.frame.width))
        #expect(resized?["height"] == Double(window.frame.height))
    }
}
