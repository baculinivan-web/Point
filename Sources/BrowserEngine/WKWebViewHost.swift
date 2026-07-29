@preconcurrency import AppKit
import BrowserCore
import SwiftUI
import WebKit

public final class WebContainerView: NSView {
    private weak var attachedWebView: WKWebView?
    private weak var pendingWebView: WKWebView?
    private var fullscreenObservation: NSKeyValueObservation?
    private let interactionShield = WebInteractionShieldView()
    private var interactionShieldWidthConstraint: NSLayoutConstraint?
    private var blockedLeadingWidth: CGFloat = 0
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

        // WebKit owns the WKWebView hierarchy while an element is fullscreen:
        // it replaces the view with a placeholder, moves it to another window,
        // then restores it on exit. Reparenting either the outgoing or incoming
        // web view during that transition can detach the fullscreen video layer
        // and leave subsequent presentations rendering only their background.
        if let attachedWebView,
           attachedWebView.fullscreenState != .notInFullscreen {
            deferAttachment(of: webView, until: attachedWebView)
            return
        }
        guard webView.fullscreenState == .notInFullscreen else {
            deferAttachment(of: webView, until: webView)
            return
        }

        fullscreenObservation?.invalidate()
        fullscreenObservation = nil
        pendingWebView = nil

        attachedWebView?.removeFromSuperview()
        attachedWebView = webView
        webView.removeFromSuperview()
        // The web view must be laid out with autoresizing, not Auto Layout
        // constraints: WebKit's element-fullscreen controller snapshots and
        // restores the web view's frame, and pinned anchor constraints can
        // zero out the fullscreen video layer's bounds when playback pauses
        // (video disappears while audio keeps going, and every following
        // fullscreen presentation stays blank).
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
        installInteractionShield(above: webView)
    }

    @MainActor
    private func deferAttachment(
        of webView: WKWebView,
        until fullscreenWebView: WKWebView
    ) {
        pendingWebView = webView
        fullscreenObservation?.invalidate()
        fullscreenObservation = fullscreenWebView.observe(
            \.fullscreenState,
            options: [.new]
        ) { [weak self, weak webView] observedWebView, _ in
            MainActor.assumeIsolated {
                guard observedWebView.fullscreenState == .notInFullscreen,
                      let self,
                      let webView,
                      self.pendingWebView === webView
                else { return }

                // Let WebKit finish returning the view to its placeholder
                // before moving it into a newly-created SwiftUI host.
                Task { @MainActor [weak self, weak webView] in
                    await Task.yield()
                    guard let self, let webView else { return }
                    self.attach(webView)
                }
            }
        }
    }

    @MainActor
    public func setBlockedLeadingWidth(_ width: CGFloat) {
        let width = max(0, width)
        blockedLeadingWidth = width
        interactionShieldWidthConstraint?.constant = width
        interactionShield.isHidden = width == 0
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

    public override func layout() {
        super.layout()
        // Autoresizing cannot track container resizes that happen while
        // WebKit hosts the web view in its fullscreen window, so realign
        // the frame once the web view is back in our hierarchy.
        if let attachedWebView,
           attachedWebView.superview === self,
           attachedWebView.fullscreenState == .notInFullscreen,
           attachedWebView.frame != bounds {
            attachedWebView.frame = bounds
        }
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
    private func installInteractionShield(above webView: WKWebView) {
        interactionShield.removeFromSuperview()
        interactionShieldWidthConstraint?.isActive = false
        addSubview(interactionShield, positioned: .above, relativeTo: webView)

        let widthConstraint = interactionShield.widthAnchor.constraint(equalToConstant: 0)
        interactionShieldWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            interactionShield.leadingAnchor.constraint(equalTo: leadingAnchor),
            interactionShield.topAnchor.constraint(equalTo: topAnchor),
            interactionShield.bottomAnchor.constraint(equalTo: bottomAnchor),
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
              convert(event.locationInWindow, from: nil).x >= blockedLeadingWidth,
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
}

public struct WKWebViewHost: NSViewRepresentable {
    public let webView: WKWebView
    public let blockedLeadingWidth: CGFloat
    private let onSwipeBack: @MainActor () -> Bool
    private let onSwipeForward: @MainActor () -> Bool

    public init(
        webView: WKWebView,
        blockedLeadingWidth: CGFloat = 0,
        onSwipeBack: @escaping @MainActor () -> Bool,
        onSwipeForward: @escaping @MainActor () -> Bool
    ) {
        self.webView = webView
        self.blockedLeadingWidth = blockedLeadingWidth
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
        return host
    }

    public func updateNSView(_ host: WebContainerView, context: Context) {
        host.attach(webView)
        host.configureNavigationGestures(
            onSwipeBack: onSwipeBack,
            onSwipeForward: onSwipeForward
        )
        host.setBlockedLeadingWidth(blockedLeadingWidth)
    }
}
