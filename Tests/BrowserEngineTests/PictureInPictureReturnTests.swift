@testable import BrowserEngine
import BrowserCore
import Foundation
import Testing

@Suite("Picture in Picture return")
struct PictureInPictureReturnTests {
    @Test("WebKit can call the Return to Tab delegate selector")
    @MainActor
    func returnSelectorIsExposed() {
        let session = WebEngineSession(tabID: TabID())
        #expect(session.responds(
            to: NSSelectorFromString("_webViewFullscreenMayReturnToInline:")
        ))
        session.invalidate()
    }
}
