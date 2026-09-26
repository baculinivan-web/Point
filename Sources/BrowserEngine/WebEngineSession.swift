@preconcurrency import AppKit
import BrowserCore
import Foundation
import WebKit

@MainActor
public protocol WebEngineEventSink: AnyObject {
    func webEngineDidChange(_ session: WebEngineSession)
    func webEngineRequestedPictureInPictureReturn(_ session: WebEngineSession)
    func webEngineDidCommit(_ session: WebEngineSession)
    func webEngineDidFinish(_ session: WebEngineSession)
    func webEngineDidFailNavigation(_ session: WebEngineSession)
    func webEngineDidCrash(_ session: WebEngineSession)
    func webEngineIsActive(_ session: WebEngineSession) -> Bool
    func webEngine(_ session: WebEngineSession, didDiscoverFaviconAt url: URL)
    func webEngine(
        _ session: WebEngineSession,
        requestsMediaPermissionFor origin: SiteOrigin,
        topLevelOrigin: SiteOrigin,
        kind: MediaPermissionKind,
        decisionHandler: @escaping @MainActor (Bool) -> Void
    )
    func webEngine(
        _ session: WebEngineSession,
        createNewTabWith configuration: WKWebViewConfiguration,
        request: URLRequest?
    ) -> WKWebView?
    func webEngine(
        _ session: WebEngineSession,
        requestsPreviewFor request: URLRequest
    )
    func webEngineRequestedClose(_ session: WebEngineSession)
}

public struct WebMediaPlayback: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case audio
        case video
    }

    public let kind: Kind
    public let isPlaying: Bool
}

@MainActor
public final class WebEngineSession: NSObject {
    public let tabID: TabID
    public let webView: WKWebView
    public weak var eventSink: (any WebEngineEventSink)?

    private let downloadManager: DownloadManager?
    private let navigationSchemePolicy = NavigationSchemePolicy()
    private var observations: [NSKeyValueObservation] = []
    private var pendingUIFlowCount = 0
    private var desiredMediaPlaybackSuspended = false
    private var appliedMediaPlaybackSuspended = false
    private var mediaSuspensionTransitionInFlight = false
    private var captureStopOperationsRemaining = 0
    private var pendingMainFrameNavigationWasBackForward = false
    private var lastMainFrameRequest: URLRequest?
    private var provisionalNavigationNeedsExplicitReload = false
    private let pictureInPictureHandlerName: String
    private let pictureInPictureHandler: VideoPictureInPictureMessageHandler
    private var videoFrames: [String: VideoFrame] = [:]
    private var automaticPictureInPictureFrameID: String?
    private var pictureInPictureRequestInFlight = false
    private var pictureInPictureShouldBeVisible = false
    private var pictureInPictureRestoreTask: Task<Void, Never>?

    private struct VideoFrame {
        let frameInfo: WKFrameInfo
        let playing: Bool
        let pictureInPicture: Bool
        let mediaPlayback: WebMediaPlayback?
        let updatedAt: Date
    }

    public var title: String {
        webView.title ?? BrowserLocalization.string("new_tab")
    }
    public var url: URL? { webView.url }
    public var estimatedProgress: Double { webView.estimatedProgress }
    public var isLoading: Bool { webView.isLoading }
    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }
    public private(set) var isPlayingMedia = false
    public var hasPlayingVideo: Bool {
        videoFrames.values.contains {
            $0.playing && Date().timeIntervalSince($0.updatedAt) < 20
        }
    }
    public var isPresentingPictureInPicture: Bool {
        videoFrames.values.contains { $0.pictureInPicture }
    }
    public var mediaPlayback: WebMediaPlayback? {
        videoFrames.values
            .filter { $0.mediaPlayback != nil }
            .sorted {
                if $0.mediaPlayback?.isPlaying != $1.mediaPlayback?.isPlaying {
                    return $0.mediaPlayback?.isPlaying == true
                }
                return $0.updatedAt > $1.updatedAt
            }
            .first?.mediaPlayback
    }
    public private(set) var hasActiveCapture = false
    public private(set) var isStoppingMediaCapture = false
    public private(set) var isElementFullscreen = false
    public private(set) var hasPendingUIFlow = false
    public private(set) var committedNavigationWasBackForward = false

    public var hasCameraCapture: Bool {
        webView.cameraCaptureState != .none
    }

    public var hasMicrophoneCapture: Bool {
        webView.microphoneCaptureState != .none
    }

    public var backItemURL: URL? {
        webView.backForwardList.backItem?.url
    }

    public var forwardItemURL: URL? {
        webView.backForwardList.forwardItem?.url
    }

    public init(
        tabID: TabID,
        configuration suppliedConfiguration: WKWebViewConfiguration? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil,
        downloadManager: DownloadManager? = nil
    ) {
        self.tabID = tabID
        self.downloadManager = downloadManager
        let handlerName = "pointPictureInPicture_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        pictureInPictureHandlerName = handlerName
        pictureInPictureHandler = VideoPictureInPictureMessageHandler()
        let configuration = suppliedConfiguration
            ?? Self.makeConfiguration(websiteDataStore: websiteDataStore)
        let contentWorld = WKContentWorld.world(name: "PointPictureInPicture")
        configuration.userContentController.add(
            pictureInPictureHandler,
            contentWorld: contentWorld,
            name: handlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: VideoPictureInPicture.observerScript(handlerName: handlerName),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: contentWorld
            )
        )
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        pictureInPictureHandler.session = self

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = _isDebugAssertConfiguration()
        observeState()
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    public func captureInteractionState() -> Any? {
        webView.interactionState
    }

    @discardableResult
    public func restoreInteractionState(_ interactionState: Any) -> Bool {
        webView.interactionState = interactionState
        return webView.interactionState != nil
    }

    public func setMediaPlaybackSuspended(_ suspended: Bool) {
        desiredMediaPlaybackSuspended = suspended
        driveMediaSuspensionTransition()
    }

    public func refreshMediaPlaybackState(
        completion: (@MainActor () -> Void)? = nil
    ) {
        webView.requestMediaPlaybackState { [weak self] state in
            guard let self else {
                completion?()
                return
            }
            let wasPlaying = isPlayingMedia
            isPlayingMedia = state == .playing
            if wasPlaying != isPlayingMedia {
                eventSink?.webEngineDidChange(self)
            }
            completion?()
        }
    }

    public func invalidate() {
        pictureInPictureRestoreTask?.cancel()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: pictureInPictureHandlerName,
            contentWorld: WKContentWorld.world(name: "PointPictureInPicture")
        )
        videoFrames.removeAll()
        eventSink = nil
    }

    /// Keeps the system PiP presentation in sync with whether this tab is
    /// visible. A failed or disallowed request leaves playback untouched.
    public func setAutomaticPictureInPictureVisible(_ visible: Bool) {
        pictureInPictureShouldBeVisible = visible
        if visible {
            restoreAutomaticPictureInPicture()
        } else {
            pictureInPictureRestoreTask?.cancel()
            pictureInPictureRestoreTask = nil
            requestAutomaticPictureInPicture()
        }
    }

    public func toggleMediaPlayback() {
        guard let frame = videoFrames.values
            .filter({ $0.mediaPlayback != nil })
            .sorted(by: {
                if $0.mediaPlayback?.isPlaying != $1.mediaPlayback?.isPlaying {
                    return $0.mediaPlayback?.isPlaying == true
                }
                return $0.updatedAt > $1.updatedAt
            })
            .first else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await webView.callAsyncJavaScript(
                VideoPictureInPicture.toggleMediaScript,
                arguments: [:],
                in: frame.frameInfo,
                contentWorld: WKContentWorld.world(name: "PointPictureInPicture")
            )
        }
    }

    private func requestAutomaticPictureInPicture() {
        guard !pictureInPictureRequestInFlight,
              automaticPictureInPictureFrameID == nil,
              !isElementFullscreen
        else { return }

        let candidates = videoFrames
            .filter { $0.value.playing && !$0.value.pictureInPicture &&
                Date().timeIntervalSince($0.value.updatedAt) < 20 }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
        guard !candidates.isEmpty else { return }

        pictureInPictureRequestInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { pictureInPictureRequestInFlight = false }
            for candidate in candidates {
                guard !pictureInPictureShouldBeVisible else { return }
                let value = try? await webView.callAsyncJavaScript(
                    VideoPictureInPicture.enterScript,
                    arguments: [:],
                    in: candidate.value.frameInfo,
                    contentWorld: WKContentWorld.world(name: "PointPictureInPicture")
                )
                if value as? Bool == true {
                    automaticPictureInPictureFrameID = candidate.key
                    if pictureInPictureShouldBeVisible {
                        restoreAutomaticPictureInPicture()
                    }
                    return
                }
            }
        }
    }

    private func restoreAutomaticPictureInPicture() {
        guard automaticPictureInPictureFrameID != nil,
              pictureInPictureRestoreTask == nil else { return }
        pictureInPictureRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, pictureInPictureShouldBeVisible,
                  let frameID = automaticPictureInPictureFrameID,
                  let frame = videoFrames[frameID] else {
                pictureInPictureRestoreTask = nil
                return
            }
            automaticPictureInPictureFrameID = nil
            _ = try? await webView.callAsyncJavaScript(
                VideoPictureInPicture.exitScript,
                arguments: [:],
                in: frame.frameInfo,
                contentWorld: WKContentWorld.world(name: "PointPictureInPicture")
            )
            pictureInPictureRestoreTask = nil
        }
    }

    fileprivate func receiveVideoState(_ message: WKScriptMessage) {
        guard let state = message.body as? [String: Any],
              let frameID = state["frameID"] as? String,
              let playing = state["playing"] as? Bool,
              let pictureInPicture = state["pictureInPicture"] as? Bool
        else { return }
        let wasPresentingPictureInPicture = isPresentingPictureInPicture
        let frameWasPresentingPictureInPicture =
            videoFrames[frameID]?.pictureInPicture == true
        let previousMediaPlayback = mediaPlayback
        let mediaPlayback: WebMediaPlayback?
        if state["mediaAvailable"] as? Bool == true,
           let kindName = state["mediaKind"] as? String,
           let kind = WebMediaPlayback.Kind(rawValue: kindName) {
            mediaPlayback = WebMediaPlayback(
                kind: kind,
                isPlaying: state["mediaPlaying"] as? Bool == true
            )
        } else {
            mediaPlayback = nil
        }
        if playing || pictureInPicture || mediaPlayback != nil {
            videoFrames[frameID] = VideoFrame(
                frameInfo: message.frameInfo,
                playing: playing,
                pictureInPicture: pictureInPicture,
                mediaPlayback: mediaPlayback,
                updatedAt: Date()
            )
        } else {
            videoFrames.removeValue(forKey: frameID)
        }
        if automaticPictureInPictureFrameID == frameID && !pictureInPicture
            && (state["pictureInPictureExited"] as? Bool == true
                || frameWasPresentingPictureInPicture
                || state["pageHidden"] as? Bool == true) {
            automaticPictureInPictureFrameID = nil
        }
        if wasPresentingPictureInPicture != isPresentingPictureInPicture
            || previousMediaPlayback != self.mediaPlayback {
            eventSink?.webEngineDidChange(self)
        }
    }

    public func load(_ url: URL) {
        load(URLRequest(url: url))
    }

    public func load(_ request: URLRequest) {
        lastMainFrameRequest = request
        provisionalNavigationNeedsExplicitReload = false
        webView.load(request)
    }

    public func loadHistoryEntry(_ url: URL) {
        load(URLRequest(url: url))
    }

    public func setNativeBackForwardGesturesEnabled(_ enabled: Bool) {
        webView.allowsBackForwardNavigationGestures = enabled
    }

    public func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    public func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    public func reload(
        bypassingCache: Bool = false,
        fallbackURL: URL? = nil
    ) {
        if let recoveryRequest = WebEngineReloadRecovery.request(
            currentURL: webView.url,
            lastMainFrameRequest: lastMainFrameRequest,
            fallbackURL: fallbackURL,
            provisionalNavigationFailed: provisionalNavigationNeedsExplicitReload,
            bypassingCache: bypassingCache
        ) {
            load(recoveryRequest)
            return
        }

        if bypassingCache, let url = webView.url {
            load(
                URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
                )
            )
        } else {
            webView.reload()
        }
    }

    public func stop() {
        webView.stopLoading()
    }

    public func stopMediaCapture() {
        guard hasActiveCapture, !isStoppingMediaCapture else { return }
        let stopCamera = hasCameraCapture
        let stopMicrophone = hasMicrophoneCapture
        captureStopOperationsRemaining = (stopCamera ? 1 : 0)
            + (stopMicrophone ? 1 : 0)
        guard captureStopOperationsRemaining > 0 else { return }

        isStoppingMediaCapture = true
        eventSink?.webEngineDidChange(self)
        if stopCamera {
            webView.setCameraCaptureState(.none) { [weak self] in
                self?.captureStopOperationFinished()
            }
        }
        if stopMicrophone {
            webView.setMicrophoneCaptureState(.none) { [weak self] in
                self?.captureStopOperationFinished()
            }
        }
    }

    /// Extracts the readable text of the current page for the AI assistant.
    public func extractPageText(limit: Int) async -> String? {
        let script = """
        (() => {
          const root = document.querySelector('article') ||
            document.querySelector('main') || document.body;
          if (!root) { return ''; }
          return root.innerText.replace(/\\n{3,}/g, '\\n\\n').slice(0, \(limit));
        })()
        """
        let value = try? await webView.evaluateJavaScript(script)
        return value as? String
    }

    /// Captures the visible page as JPEG for the chat's screenshot tool.
    public func captureSnapshot(maxWidth: CGFloat = 1200) async -> Data? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(maxWidth))
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.75]
        )
    }

    public func find(_ text: String) {
        guard !text.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.wraps = true
        Task { @MainActor in
            _ = try? await webView.find(text, configuration: configuration)
        }
    }

    private static func makeConfiguration(
        websiteDataStore: WKWebsiteDataStore?
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore ?? .default()
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.suppressesIncrementalRendering = false
        configuration.allowsAirPlayForMediaPlayback = true

        let preferences = WKPreferences()
        preferences.isFraudulentWebsiteWarningEnabled = true
        preferences.javaScriptCanOpenWindowsAutomatically = true
        preferences.isElementFullscreenEnabled = true
        // Safari enables this WebKit preference, but WKWebView does not expose
        // a public macOS setter. Without it both video PiP APIs reject even a
        // playing local MP4. Check the selector so older WebKit versions keep
        // their existing behavior instead of failing at runtime.
        if preferences.responds(
            to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        ) {
            preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        configuration.preferences = preferences

        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.preferredContentMode = .desktop
        configuration.defaultWebpagePreferences = webpagePreferences
        configuration.applicationNameForUserAgent = desktopSafariUserAgentSuffix
        return configuration
    }

    private static var desktopSafariUserAgentSuffix: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(version.majorVersion).\(version.minorVersion) Safari/605.1.15"
    }

    private func observeState() {
        observations = [
            observation(for: \WKWebView.title),
            observation(for: \WKWebView.url),
            observation(for: \WKWebView.estimatedProgress),
            observation(for: \WKWebView.isLoading),
            observation(for: \WKWebView.canGoBack),
            observation(for: \WKWebView.canGoForward),
            observation(for: \WKWebView.cameraCaptureState),
            observation(for: \WKWebView.microphoneCaptureState),
            observation(for: \WKWebView.fullscreenState)
        ]
    }

    private func observation<Value>(
        for keyPath: KeyPath<WKWebView, Value>
    ) -> NSKeyValueObservation {
        webView.observe(keyPath, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshProtectionState()
                self.eventSink?.webEngineDidChange(self)
            }
        }
    }

    private func refreshProtectionState() {
        hasActiveCapture = webView.cameraCaptureState != .none
            || webView.microphoneCaptureState != .none
        isElementFullscreen = webView.fullscreenState != .notInFullscreen
    }

    private func captureStopOperationFinished() {
        captureStopOperationsRemaining = max(0, captureStopOperationsRemaining - 1)
        guard captureStopOperationsRemaining == 0 else { return }
        isStoppingMediaCapture = false
        refreshProtectionState()
        eventSink?.webEngineDidChange(self)
    }

    private func setPendingUIFlow(_ isPending: Bool) {
        if isPending {
            pendingUIFlowCount += 1
        } else {
            pendingUIFlowCount = max(0, pendingUIFlowCount - 1)
        }
        let newValue = pendingUIFlowCount > 0
        guard hasPendingUIFlow != newValue else { return }
        hasPendingUIFlow = newValue
        eventSink?.webEngineDidChange(self)
    }

    private func driveMediaSuspensionTransition() {
        guard !mediaSuspensionTransitionInFlight,
              desiredMediaPlaybackSuspended != appliedMediaPlaybackSuspended
        else { return }

        let requestedState = desiredMediaPlaybackSuspended
        mediaSuspensionTransitionInFlight = true
        webView.setAllMediaPlaybackSuspended(requestedState) { [weak self] in
            guard let self else { return }
            appliedMediaPlaybackSuspended = requestedState
            mediaSuspensionTransitionInFlight = false
            driveMediaSuspensionTransition()
        }
    }
}

@MainActor
private final class VideoPictureInPictureMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: WebEngineSession?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        session?.receiveVideoState(message)
    }
}

extension WebEngineSession: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard eventSink?.webEngineIsActive(self) == true,
              challenge.previousFailureCount == 0
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        setPendingUIFlow(true)
        defer { setPendingUIFlow(false) }

        let username = NSTextField(string: challenge.proposedCredential?.user ?? "")
        username.placeholderString = BrowserLocalization.string("username")
        let password = NSSecureTextField(string: "")
        password.placeholderString = BrowserLocalization.string("password")
        let fields = NSStackView(views: [username, password])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 320, height: 58)

        let alert = NSAlert()
        alert.messageText = BrowserLocalization.string(
            "sign_in_to_host",
            challenge.protectionSpace.host
        )
        if let realm = challenge.protectionSpace.realm, !realm.isEmpty {
            alert.informativeText = BrowserLocalization.string(
                "authentication_realm",
                realm
            )
        } else {
            alert.informativeText = BrowserLocalization.string(
                "authentication_request"
            )
        }
        alert.accessoryView = fields
        alert.addButton(withTitle: BrowserLocalization.string("sign_in"))
        alert.addButton(withTitle: BrowserLocalization.string("cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let credential = URLCredential(
            user: username.stringValue,
            password: password.stringValue,
            persistence: .none
        )
        completionHandler(.useCredential, credential)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased()
        else {
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true {
            pendingMainFrameNavigationWasBackForward =
                navigationAction.navigationType == .backForward
        }

        let disposition = navigationSchemePolicy.disposition(for: url)
        if disposition == .allowInWebView,
           navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.shift) {
            decisionHandler(.cancel)
            eventSink?.webEngine(self, requestsPreviewFor: navigationAction.request)
            return
        }

        if disposition == .allowInWebView,
           navigationAction.targetFrame?.isMainFrame == true {
            lastMainFrameRequest = navigationAction.request
            provisionalNavigationNeedsExplicitReload = false
        }

        switch disposition {
        case .allowInWebView where ["http", "https", "blob"].contains(scheme):
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .allowInWebView:
            decisionHandler(.allow)
        case .confirmExternalApplication:
            decisionHandler(.cancel)
            confirmOpeningExternalURL(url)
        case .block:
            decisionHandler(.cancel)
        }
    }

    private func confirmOpeningExternalURL(_ url: URL) {
        guard eventSink?.webEngineIsActive(self) == true else { return }
        setPendingUIFlow(true)
        defer { setPendingUIFlow(false) }

        let scheme = url.scheme?.lowercased() ?? "external"
        let alert = NSAlert()
        alert.messageText = BrowserLocalization.string("open_in_other_app")
        alert.informativeText = BrowserLocalization.string(
            "external_url_details",
            scheme,
            url.absoluteString
        )
        alert.addButton(withTitle: BrowserLocalization.string("open"))
        alert.addButton(withTitle: BrowserLocalization.string("cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased()
        let isAttachment = disposition?.contains("attachment") == true
        decisionHandler(
            isAttachment || !navigationResponse.canShowMIMEType
                ? .download
                : .allow
        )
    }

    public func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        downloadManager?.begin(download)
    }

    public func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        downloadManager?.begin(download)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        provisionalNavigationNeedsExplicitReload = false
        videoFrames.removeAll()
        automaticPictureInPictureFrameID = nil
        committedNavigationWasBackForward = pendingMainFrameNavigationWasBackForward
        pendingMainFrameNavigationWasBackForward = false
        eventSink?.webEngineDidCommit(self)
        committedNavigationWasBackForward = false
        eventSink?.webEngineDidChange(self)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        eventSink?.webEngineDidFinish(self)
        eventSink?.webEngineDidChange(self)
        discoverFavicon()
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        pendingMainFrameNavigationWasBackForward = false
        eventSink?.webEngineDidFailNavigation(self)
        eventSink?.webEngineDidChange(self)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        provisionalNavigationNeedsExplicitReload = true
        pendingMainFrameNavigationWasBackForward = false
        eventSink?.webEngineDidFailNavigation(self)
        eventSink?.webEngineDidChange(self)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        eventSink?.webEngineDidCrash(self)
    }

    private func discoverFavicon() {
        Task { @MainActor [weak self] in
            guard let self, let pageURL = webView.url else { return }
            let script = """
            (() => {
              const links = Array.from(document.querySelectorAll('link[rel]'));
              const icon = links.find(link =>
                link.rel.toLowerCase().split(/\\s+/).includes('icon') && link.href
              );
              return icon ? icon.href : new URL('/favicon.ico', document.baseURI).href;
            })()
            """
            guard let value = try? await webView.evaluateJavaScript(script),
                  let address = value as? String,
                  let iconURL = URL(string: address, relativeTo: pageURL)?.absoluteURL,
                  ["http", "https"].contains(iconURL.scheme?.lowercased() ?? "")
            else { return }
            eventSink?.webEngine(self, didDiscoverFaviconAt: iconURL)
        }
    }
}

extension WebEngineSession: WKUIDelegate {
    /// WebKit calls this private delegate selector when the system PiP window's
    /// Return to Tab button is pressed, before it dismisses the video window.
    @objc(_webViewFullscreenMayReturnToInline:)
    public func pictureInPictureMayReturnToInline(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        eventSink?.webEngineRequestedPictureInPictureReturn(self)
    }

    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let kind: MediaPermissionKind
        switch type {
        case .camera:
            kind = .camera
        case .microphone:
            kind = .microphone
        case .cameraAndMicrophone:
            kind = .cameraAndMicrophone
        @unknown default:
            decisionHandler(.deny)
            return
        }
        guard let requestingOrigin = SiteOrigin(
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port
        ) else {
            decisionHandler(.deny)
            return
        }
        let topLevelOrigin = SiteOrigin(url: webView.url) ?? requestingOrigin

        setPendingUIFlow(true)
        let completion = OneShotMediaPermissionDecision { [weak self] allowed in
            self?.setPendingUIFlow(false)
            decisionHandler(allowed ? .grant : .deny)
        }
        guard let eventSink else {
            completion.resolve(false)
            return
        }
        eventSink.webEngine(
            self,
            requestsMediaPermissionFor: requestingOrigin,
            topLevelOrigin: topLevelOrigin,
            kind: kind,
            decisionHandler: completion.resolve
        )
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        eventSink?.webEngine(
            self,
            createNewTabWith: configuration,
            request: navigationAction.request
        )
    }

    public func webViewDidClose(_ webView: WKWebView) {
        eventSink?.webEngineRequestedClose(self)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        setPendingUIFlow(true)
        defer { setPendingUIFlow(false) }
        let alert = NSAlert()
        alert.messageText = webView.url?.host
            ?? BrowserLocalization.string("web_page")
        alert.informativeText = message
        alert.addButton(withTitle: BrowserLocalization.string("ok"))
        alert.runModal()
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        setPendingUIFlow(true)
        defer { setPendingUIFlow(false) }
        let alert = NSAlert()
        alert.messageText = webView.url?.host
            ?? BrowserLocalization.string("web_page")
        alert.informativeText = message
        alert.addButton(withTitle: BrowserLocalization.string("ok"))
        alert.addButton(withTitle: BrowserLocalization.string("cancel"))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        guard eventSink?.webEngineIsActive(self) == true else {
            completionHandler(nil)
            return
        }

        setPendingUIFlow(true)
        defer { setPendingUIFlow(false) }
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = frame.request.url?.host
            ?? webView.url?.host
            ?? BrowserLocalization.string("web_page")
        alert.informativeText = prompt
        alert.accessoryView = input
        alert.addButton(withTitle: BrowserLocalization.string("ok"))
        alert.addButton(withTitle: BrowserLocalization.string("cancel"))
        completionHandler(
            alert.runModal() == .alertFirstButtonReturn
                ? input.stringValue
                : nil
        )
    }

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        setPendingUIFlow(true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            self.setPendingUIFlow(false)
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

}

@MainActor
private final class OneShotMediaPermissionDecision {
    private var handler: ((Bool) -> Void)?

    init(handler: @escaping @MainActor (Bool) -> Void) {
        self.handler = handler
    }

    func resolve(_ allowed: Bool) {
        guard let handler else { return }
        self.handler = nil
        handler(allowed)
    }
}
