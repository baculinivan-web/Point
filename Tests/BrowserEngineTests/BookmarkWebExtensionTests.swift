@testable import BrowserEngine
import Testing
import WebKit

@MainActor
@Suite("Bookmark web extension")
struct BookmarkWebExtensionTests {
    @Test("A shared content controller is configured only once")
    func sharedContentControllerIsConfiguredOnce() {
        let originalConfiguration = WKWebViewConfiguration()
        let popupConfiguration = WKWebViewConfiguration()
        popupConfiguration.userContentController =
            originalConfiguration.userContentController

        BookmarkWebExtension.shared.configure(originalConfiguration)
        BookmarkWebExtension.shared.configure(popupConfiguration)
    }
}
