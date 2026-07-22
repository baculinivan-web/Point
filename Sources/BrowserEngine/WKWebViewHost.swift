@preconcurrency import AppKit
import BrowserCore
import SwiftUI
import WebKit

public final class WebContainerView: NSView {
    private weak var attachedWebView: WKWebView?
    private let interactionShield = WebInteractionShieldView()
    private var interactionShieldWidthConstraint: NSLayoutConstraint?
    private var swipeMonitor: Any?
    private var onSwipeBack: (@MainActor () -> Bool)?
    private var onSwipeForward: (@MainActor () -> Bool)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prepareInteractionShield()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepareInteractionShield()
    }

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
        installInteractionShield(in: webView)
    }

    @MainActor
    public func setBlockedLeadingWidth(_ width: CGFloat) {
        let width = max(0, width)
        interactionShieldWidthConstraint?.constant = width
        interactionShield.isHidden = width == 0
    }

    @MainActor
    public func setPagePointerInteractionBlocked(_ blocked: Bool) {
        guard let webView = attachedWebView else { return }

        let script: String
        if blocked {
            script = """
                (() => {
                    const id = '__point_page_pointer_lock';
                    if (document.getElementById(id)) return;
                    const style = document.createElement('style');
                    style.id = id;
                    style.textContent = `
                        :root, :root *, :root *::before, :root *::after {
                            pointer-events: none !important;
                            user-select: none !important;
                        }
                    `;
                    (document.head || document.documentElement).appendChild(style);
                })();
                """
        } else {
            script = """
                document.getElementById('__point_page_pointer_lock')?.remove();
                """
        }

        webView.evaluateJavaScript(script, completionHandler: nil)
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
    private func prepareInteractionShield() {
        interactionShield.translatesAutoresizingMaskIntoConstraints = false
        interactionShield.isHidden = true
    }

    @MainActor
    private func installInteractionShield(in webView: WKWebView) {
        interactionShield.removeFromSuperview()
        interactionShieldWidthConstraint?.isActive = false
        webView.addSubview(interactionShield, positioned: .above, relativeTo: nil)

        let widthConstraint = interactionShield.widthAnchor.constraint(equalToConstant: 0)
        interactionShieldWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            interactionShield.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            interactionShield.topAnchor.constraint(equalTo: webView.topAnchor),
            interactionShield.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            widthConstraint
        ])
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

@MainActor
private final class WebInteractionShieldView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

public struct WKWebViewHost: NSViewRepresentable {
    public let webView: WKWebView
    public let blockedLeadingWidth: CGFloat
    public let blocksPagePointerInteraction: Bool
    private let onSwipeBack: @MainActor () -> Bool
    private let onSwipeForward: @MainActor () -> Bool

    public init(
        webView: WKWebView,
        blockedLeadingWidth: CGFloat = 0,
        blocksPagePointerInteraction: Bool = false,
        onSwipeBack: @escaping @MainActor () -> Bool,
        onSwipeForward: @escaping @MainActor () -> Bool
    ) {
        self.webView = webView
        self.blockedLeadingWidth = blockedLeadingWidth
        self.blocksPagePointerInteraction = blocksPagePointerInteraction
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
        host.setBlockedLeadingWidth(blockedLeadingWidth)
        host.setPagePointerInteractionBlocked(blocksPagePointerInteraction)
        return host
    }

    public func updateNSView(_ host: WebContainerView, context: Context) {
        host.attach(webView)
        host.configureNavigationGestures(
            onSwipeBack: onSwipeBack,
            onSwipeForward: onSwipeForward
        )
        host.setBlockedLeadingWidth(blockedLeadingWidth)
        host.setPagePointerInteractionBlocked(blocksPagePointerInteraction)
    }
}
