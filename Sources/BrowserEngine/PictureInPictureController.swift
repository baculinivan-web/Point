@preconcurrency import AppKit
import WebKit

/// A browser-owned PiP window. Keeping the existing `WKWebView` alive inside
/// this panel means sites using a custom video stack (notably YouTube) retain
/// their current stream, playback position, and authenticated session.
@MainActor
public final class PictureInPictureController: NSObject, NSWindowDelegate {
    public enum StopReason: Equatable {
        case closed
        case returnedToTab
    }

    private var panel: PictureInPicturePanel?
    private weak var webView: WKWebView?
    private var onStop: ((StopReason) -> Void)?
    private var isStopping = false

    public var isPresented: Bool { panel != nil }

    public func present(
        webView: WKWebView,
        title: String,
        onStop: @escaping (StopReason) -> Void
    ) {
        guard panel == nil else { return }

        self.webView = webView
        self.onStop = onStop
        let panel = PictureInPicturePanel(title: title)
        panel.delegate = self
        panel.contentController.onTogglePlayback = { [weak self] in
            self?.togglePlayback()
        }
        panel.contentController.onReturnToTab = { [weak self] in
            self?.stop(.returnedToTab, shouldPausePlayback: false)
        }
        panel.contentController.onClose = { [weak self] in
            self?.stop(.closed, shouldPausePlayback: true)
        }
        panel.contentController.attach(webView)
        self.panel = panel
        prepareWebVideoForPictureInPicture()
        refreshPlaybackButton()
        panel.makeKeyAndOrderFront(nil)
    }

    public func stopIfPresenting(_ candidate: WKWebView) {
        guard webView === candidate else { return }
        stop(.closed, shouldPausePlayback: true)
    }

    public func stop() {
        stop(.closed, shouldPausePlayback: true)
    }

    private func stop(_ reason: StopReason, shouldPausePlayback: Bool) {
        guard !isStopping, let panel else { return }
        isStopping = true
        if shouldPausePlayback { pausePlayback() }
        restoreWebVideoAfterPictureInPicture()
        panel.contentController.detachWebView()
        self.panel = nil
        webView = nil
        panel.orderOut(nil)
        let completion = onStop
        onStop = nil
        isStopping = false
        completion?(reason)
    }

    private func togglePlayback() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.togglePlaybackScript) { [weak self] _, _ in
            Task { @MainActor in self?.refreshPlaybackButton() }
        }
    }

    private func pausePlayback() {
        webView?.evaluateJavaScript(Self.pausePlaybackScript)
    }

    private func refreshPlaybackButton() {
        guard let webView, let panel else { return }
        webView.evaluateJavaScript(Self.playbackStateScript) { [weak panel] result, _ in
            let isPaused = (result as? Bool) ?? false
            Task { @MainActor in panel?.contentController.setPlaybackPaused(isPaused) }
        }
    }

    private func prepareWebVideoForPictureInPicture() {
        webView?.evaluateJavaScript(Self.prepareVideoScript)
    }

    private func restoreWebVideoAfterPictureInPicture() {
        webView?.evaluateJavaScript(Self.restoreVideoScript)
    }

    public func windowWillClose(_ notification: Notification) {
        stop(.closed, shouldPausePlayback: true)
    }

    private static let prepareVideoScript = """
    (() => {
      const styleID = '__pointPictureInPictureStyle';
      if (document.getElementById(styleID)) return;
      const video = Array.from(document.querySelectorAll('video'))
        .filter(video => !video.paused && !video.ended && video.readyState >= 1)
        .sort((lhs, rhs) => (rhs.videoWidth * rhs.videoHeight) - (lhs.videoWidth * lhs.videoHeight))[0];
      if (!video) return;
      const style = document.createElement('style');
      style.id = styleID;
      style.textContent = `
        html, body { background: #000 !important; overflow: hidden !important; }
        video { position: fixed !important; inset: 0 !important; z-index: 2147483646 !important;
                width: 100vw !important; height: 100vh !important; object-fit: contain !important; }
        #movie_player, .html5-video-player { position: fixed !important; inset: 0 !important;
                z-index: 2147483645 !important; width: 100vw !important; height: 100vh !important; }
      `;
      document.head.appendChild(style);
    })()
    """

    private static let restoreVideoScript = """
    document.getElementById('__pointPictureInPictureStyle')?.remove()
    """

    private static let playbackStateScript = """
    (() => !Array.from(document.querySelectorAll('video')).some(video => !video.paused && !video.ended))()
    """

    private static let togglePlaybackScript = """
    (() => {
      const video = Array.from(document.querySelectorAll('video'))
        .sort((lhs, rhs) => (rhs.videoWidth * rhs.videoHeight) - (lhs.videoWidth * lhs.videoHeight))[0];
      if (!video) return false;
      if (video.paused) { void video.play(); } else { video.pause(); }
      return true;
    })()
    """

    private static let pausePlaybackScript = """
    Array.from(document.querySelectorAll('video')).forEach(video => video.pause())
    """
}

@MainActor
private final class PictureInPicturePanel: NSPanel {
    let contentController = PictureInPictureContentView()

    init(title: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 292),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = title
        contentView = contentController
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isOpaque = true
        backgroundColor = .black
        minSize = NSSize(width: 280, height: 180)
        setFrameAutosaveName("BrowserPictureInPicture")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PictureInPictureContentView: NSView {
    var onTogglePlayback: (() -> Void)?
    var onReturnToTab: (() -> Void)?
    var onClose: (() -> Void)?

    private let controls = PictureInPictureControlsView()
    private weak var attachedWebView: WKWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        controls.onTogglePlayback = { [weak self] in self?.onTogglePlayback?() }
        controls.onReturnToTab = { [weak self] in self?.onReturnToTab?() }
        controls.onClose = { [weak self] in self?.onClose?() }
        addSubview(controls)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        attachedWebView?.frame = bounds
        controls.frame = NSRect(
            x: 10,
            y: bounds.height - 48,
            width: bounds.width - 20,
            height: 38
        )
    }

    func attach(_ webView: WKWebView) {
        attachedWebView = webView
        webView.removeFromSuperview()
        addSubview(webView, positioned: .below, relativeTo: controls)
        needsLayout = true
    }

    func detachWebView() {
        attachedWebView?.removeFromSuperview()
        attachedWebView = nil
    }

    func setPlaybackPaused(_ isPaused: Bool) {
        controls.setPlaybackPaused(isPaused)
    }
}

@MainActor
private final class PictureInPictureControlsView: NSVisualEffectView {
    var onTogglePlayback: (() -> Void)?
    var onReturnToTab: (() -> Void)?
    var onClose: (() -> Void)?

    private let playPauseButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let returnButton = button(
            symbol: "rectangle.portrait.and.arrow.right",
            label: "Return to tab",
            action: #selector(returnToTab)
        )
        configure(playPauseButton, symbol: "pause.fill", label: "Pause", action: #selector(togglePlayback))
        let closeButton = button(symbol: "xmark", label: "Close Picture in Picture", action: #selector(close))

        let stack = NSStackView(views: [returnButton, playPauseButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { true }

    func setPlaybackPaused(_ isPaused: Bool) {
        playPauseButton.image = NSImage(
            systemSymbolName: isPaused ? "play.fill" : "pause.fill",
            accessibilityDescription: isPaused ? "Play" : "Pause"
        )
        playPauseButton.toolTip = isPaused ? "Play" : "Pause"
    }

    private func button(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton()
        configure(button, symbol: symbol, label: label, action: action)
        return button
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.contentTintColor = .white
        button.target = self
        button.action = action
    }

    @objc private func togglePlayback() { onTogglePlayback?() }
    @objc private func returnToTab() { onReturnToTab?() }
    @objc private func close() { onClose?() }
}
