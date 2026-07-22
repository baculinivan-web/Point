@preconcurrency import AppKit
import BrowserCore
import SwiftUI
import WebKit

public final class WebContainerView: NSView {
    private weak var attachedWebView: WKWebView?
    private var swipeMonitor: Any?
    private var onSwipeBack: (@MainActor () -> Bool)?
    private var onSwipeForward: (@MainActor () -> Bool)?

    @MainActor
    public func attach(_ webView: WKWebView) {
        guard attachedWebView !== webView else { return }

        attachedWebView?.removeFromSuperview()
        attachedWebView = webView
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @MainActor
    public func configureNavigationGestures(
        onSwipeBack: @escaping @MainActor () -> Bool,
        onSwipeForward: @escaping @MainActor () -> Bool
    ) {
        self.onSwipeBack = onSwipeBack
        self.onSwipeForward = onSwipeForward
        installSwipeMonitorIfNeeded()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeSwipeMonitor()
        } else {
            installSwipeMonitorIfNeeded()
        }
    }

    @MainActor
    private func installSwipeMonitorIfNeeded() {
        guard swipeMonitor == nil, window != nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) {
            [weak self] event in
            self?.handleSwipeEvent(event) ?? event
        }
    }

    @MainActor
    private func removeSwipeMonitor() {
        guard let swipeMonitor else { return }
        NSEvent.removeMonitor(swipeMonitor)
        self.swipeMonitor = nil
    }

    @MainActor
    private func handleSwipeEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let webView = attachedWebView,
              let direction = NavigationSwipeDirection(
                  deltaX: Double(event.deltaX),
                  deltaY: Double(event.deltaY)
              )
        else { return event }

        switch direction {
        case .back:
            if webView.allowsBackForwardNavigationGestures, webView.canGoBack {
                return event
            }
            return onSwipeBack?() == true ? nil : event
        case .forward:
            if webView.allowsBackForwardNavigationGestures, webView.canGoForward {
                return event
            }
            return onSwipeForward?() == true ? nil : event
        }
    }
}

public struct WKWebViewHost: NSViewRepresentable {
    public let webView: WKWebView
    private let onSwipeBack: @MainActor () -> Bool
    private let onSwipeForward: @MainActor () -> Bool

    public init(
        webView: WKWebView,
        onSwipeBack: @escaping @MainActor () -> Bool,
        onSwipeForward: @escaping @MainActor () -> Bool
    ) {
        self.webView = webView
        self.onSwipeBack = onSwipeBack
        self.onSwipeForward = onSwipeForward
    }

    public func makeNSView(context: Context) -> WebContainerView {
        let host = WebContainerView()
        host.attach(webView)
        host.configureNavigationGestures(
            onSwipeBack: onSwipeBack,
            onSwipeForward: onSwipeForward
        )
        return host
    }

    public func updateNSView(_ host: WebContainerView, context: Context) {
        host.attach(webView)
        host.configureNavigationGestures(
            onSwipeBack: onSwipeBack,
            onSwipeForward: onSwipeForward
        )
    }
}
