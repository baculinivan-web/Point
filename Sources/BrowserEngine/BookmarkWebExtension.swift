@preconcurrency import WebKit
import Foundation

@MainActor
final class BookmarkWebExtension: NSObject, WKScriptMessageHandler {
    static let shared = BookmarkWebExtension()

    private let sessions = NSHashTable<WebEngineSession>.weakObjects()
    private let configuredContentControllers =
        NSHashTable<WKUserContentController>.weakObjects()

    private static let linkHandlerName = "saveBookmarkLink"
    private static let linkCaptureScript = """
    document.addEventListener('contextmenu', function(event) {
      const link = event.composedPath().find(function(node) {
        return node instanceof HTMLAnchorElement && node.href;
      }) || (event.target.closest && event.target.closest('a[href]'));
      if (!link || !link.href) {
        return;
      }
      const url = new URL(link.href, document.baseURI);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') {
        return;
      }
      event.preventDefault();
      window.webkit.messageHandlers.saveBookmarkLink.postMessage({
        url: url.href,
        title: (link.textContent || link.title || document.title || '').trim(),
        x: event.clientX,
        y: event.clientY
      });
    }, true);
    """

    func register(_ session: WebEngineSession) {
        sessions.add(session)
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        let contentController = configuration.userContentController
        guard !configuredContentControllers.contains(contentController) else {
            return
        }
        contentController.add(self, name: Self.linkHandlerName)
        contentController.addUserScript(
            WKUserScript(
                source: Self.linkCaptureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuredContentControllers.add(contentController)
    }

    func unregister(_ session: WebEngineSession) {
        sessions.remove(session)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.linkHandlerName,
              let webView = message.webView,
              let session = sessions.allObjects.first(where: {
                  $0.webView === webView
              })
        else { return }
        session.captureContextMenuBookmark(from: message.body)
    }
}
