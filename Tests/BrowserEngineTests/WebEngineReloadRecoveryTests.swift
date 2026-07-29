@testable import BrowserEngine
import Foundation
import Testing

@Suite("Web engine reload recovery")
struct WebEngineReloadRecoveryTests {
    @Test("A blank web view reloads the tab's fallback URL")
    func blankWebViewUsesFallbackURL() throws {
        let fallbackURL = try #require(URL(string: "https://www.youtube.com/"))

        let request = WebEngineReloadRecovery.request(
            currentURL: nil,
            lastMainFrameRequest: nil,
            fallbackURL: fallbackURL,
            provisionalNavigationFailed: false,
            bypassingCache: false
        )

        #expect(request?.url == fallbackURL)
        #expect(request?.cachePolicy == .useProtocolCachePolicy)
    }

    @Test("A provisional failure retries the attempted request, not the old page")
    func provisionalFailureRetriesAttemptedRequest() throws {
        let oldURL = try #require(URL(string: "https://example.com/"))
        let attemptedURL = try #require(URL(string: "https://www.youtube.com/watch?v=test"))
        let attemptedRequest = URLRequest(url: attemptedURL)

        let request = WebEngineReloadRecovery.request(
            currentURL: oldURL,
            lastMainFrameRequest: attemptedRequest,
            fallbackURL: oldURL,
            provisionalNavigationFailed: true,
            bypassingCache: false
        )

        #expect(request?.url == attemptedURL)
    }

    @Test("Recovery can bypass every URL cache")
    func recoveryCanBypassCache() throws {
        let attemptedURL = try #require(URL(string: "https://www.youtube.com/"))

        let request = WebEngineReloadRecovery.request(
            currentURL: nil,
            lastMainFrameRequest: URLRequest(url: attemptedURL),
            fallbackURL: nil,
            provisionalNavigationFailed: true,
            bypassingCache: true
        )

        #expect(request?.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test("A committed page keeps WebKit's native reload path")
    func committedPageUsesNativeReload() throws {
        let currentURL = try #require(URL(string: "https://example.com/"))

        let request = WebEngineReloadRecovery.request(
            currentURL: currentURL,
            lastMainFrameRequest: URLRequest(url: currentURL),
            fallbackURL: currentURL,
            provisionalNavigationFailed: false,
            bypassingCache: false
        )

        #expect(request == nil)
    }
}
