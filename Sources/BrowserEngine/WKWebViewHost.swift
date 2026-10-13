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
    private var pointerMonitor: Any?
    /// Whether WebKit's own mouse-moved tracking area currently reports the
    /// pointer as inside the web view.
    private var isPointerInsideWebViewTracking = false
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
        // The new web view's tracking area starts out unentered.
        isPointerInsideWebViewTracking = false
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
            removePointerMonitor()
        } else {
            installSwipeMonitorIfNeeded()
            installPointerMonitorIfNeeded()
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

    /// The page runs underneath the window's transparent titlebar
    /// (`fullSizeContentView`). AppKit lets clicks through that strip but
    /// treats it as covering the views below for mouse tracking, so WKWebView
    /// gets `mouseExited` as soon as the pointer enters it and stops receiving
    /// `mouseMoved`. Hover state on the page then freezes — top-of-page
    /// navigation bars never highlight, and the stale state persists into
    /// menus they open. While WebKit's tracking says the pointer is outside but
    /// it is actually over the page, hand the moves to the owner of WebKit's
    /// tracking area, exactly as AppKit would have. WKWebView itself does not
    /// handle `mouseMoved:`; its tracking-area owner does, and re-checks that
    /// the web view is topmost under the pointer before acting on it.
    @MainActor
    private func installPointerMonitorIfNeeded() {
        guard pointerMonitor == nil, let window else { return }
        // Without this the window only generates moves inside tracking areas,
        // and none are active under the titlebar.
        window.acceptsMouseMovedEvents = true
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .mouseExited]
        ) { [weak self] event in
            self?.handlePointerEvent(event)
            return event
        }
    }

    @MainActor
    private func removePointerMonitor() {
        guard let pointerMonitor else { return }
        NSEvent.removeMonitor(pointerMonitor)
        self.pointerMonitor = nil
        isPointerInsideWebViewTracking = false
    }

    @MainActor
    private func handlePointerEvent(_ event: NSEvent) {
        guard event.window === window, let webView = attachedWebView else { return }

        let moveTrackingArea = webView.trackingAreas.first {
            $0.options.contains(.mouseMoved)
        }

        switch event.type {
        case .mouseEntered, .mouseExited:
            guard let area = event.trackingArea, area === moveTrackingArea else { return }
            isPointerInsideWebViewTracking = event.type == .mouseEntered
        case .mouseMoved:
            // Inside its tracking area WebKit already receives these moves.
            guard !isPointerInsideWebViewTracking,
                  webView.fullscreenState == .notInFullscreen,
                  let owner = moveTrackingArea?.owner,
                  isPointerOverWebView(event.locationInWindow, webView: webView)
            else { return }
            (owner as AnyObject).mouseMoved?(with: event)
        default:
            break
        }
    }

    /// True only when nothing else (sidebar, overlays) sits above the page at
    /// this point, so forwarded moves never reach the page through them.
    @MainActor
    private func isPointerOverWebView(_ locationInWindow: NSPoint, webView: WKWebView) -> Bool {
        guard let frameView = window?.contentView?.superview,
              let hitView = frameView.hitTest(frameView.convert(locationInWindow, from: nil))
        else { return false }
        return hitView === webView || hitView.isDescendant(of: webView)
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
