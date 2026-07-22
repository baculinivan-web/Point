import BrowserCore
import Foundation
import Testing

@Suite("Navigation scheme policy")
struct NavigationSchemePolicyTests {
    private let policy = NavigationSchemePolicy()

    @Test("WebKit-safe schemes stay in the web view")
    func webSchemes() {
        #expect(policy.disposition(for: URL(string: "https://example.com")!) == .allowInWebView)
        #expect(policy.disposition(for: URL(string: "http://localhost")!) == .allowInWebView)
        #expect(policy.disposition(for: URL(string: "about:blank")!) == .allowInWebView)
        #expect(policy.disposition(for: URL(string: "blob:https://example.com/id")!) == .allowInWebView)
    }

    @Test("Known external schemes require confirmation")
    func externalSchemes() {
        #expect(policy.disposition(for: URL(string: "mailto:test@example.com")!) == .confirmExternalApplication)
        #expect(policy.disposition(for: URL(string: "tel:+10000000000")!) == .confirmExternalApplication)
        #expect(policy.disposition(for: URL(string: "facetime:test@example.com")!) == .confirmExternalApplication)
    }

    @Test("Unknown and privileged schemes are blocked")
    func blockedSchemes() {
        #expect(policy.disposition(for: URL(string: "javascript:alert(1)")!) == .block)
        #expect(policy.disposition(for: URL(fileURLWithPath: "/tmp/test")) == .block)
        #expect(policy.disposition(for: URL(string: "custom-app://payload")!) == .block)
    }
}

@Suite("Favicon cache key")
struct FaviconCacheKeyTests {
    @Test("Pages from one origin share a stable key")
    func sameOrigin() {
        let first = FaviconCacheKey.make(for: URL(string: "https://example.com/one")!)
        let second = FaviconCacheKey.make(for: URL(string: "https://EXAMPLE.com/two?q=1")!)
        #expect(first == second)
    }

    @Test("Scheme and non-default port isolate favicon entries")
    func isolatedOrigins() {
        let secure = FaviconCacheKey.make(for: URL(string: "https://example.com")!)
        let insecure = FaviconCacheKey.make(for: URL(string: "http://example.com")!)
        let customPort = FaviconCacheKey.make(for: URL(string: "https://example.com:8443")!)
        #expect(secure != insecure)
        #expect(secure != customPort)
    }
}
