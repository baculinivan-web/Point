@preconcurrency import AppKit
import BrowserCore
import Foundation
import WebKit

@MainActor
public protocol WebEngineEventSink: AnyObject {
    func webEngineDidChange(_ session: WebEngineSession)
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
    func webEngineRequestedClose(_ session: WebEngineSession)
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

    public var title: String { webView.title ?? "Новая вкладка" }
    public var url: URL? { webView.url }
    public var estimatedProgress: Double { webView.estimatedProgress }
    public var isLoading: Bool { webView.isLoading }
    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }
    public private(set) var isPlayingMedia = false
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

        let configuration = suppliedConfiguration
            ?? Self.makeConfiguration(websiteDataStore: websiteDataStore)
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

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
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        eventSink = nil
    }

    public func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    public func load(_ request: URLRequest) {
        webView.load(request)
    }

    public func loadHistoryEntry(_ url: URL) {
        webView.load(URLRequest(url: url))
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

    public func reload(bypassingCache: Bool = false) {
        if bypassingCache, let url = webView.url {
            webView.load(
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
        username.placeholderString = "Имя пользователя"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Пароль"
        let fields = NSStackView(views: [username, password])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 320, height: 58)

        let alert = NSAlert()
        alert.messageText = "Вход на \(challenge.protectionSpace.host)"
        if let realm = challenge.protectionSpace.realm, !realm.isEmpty {
            alert.informativeText = "Сервер запрашивает имя пользователя и пароль. Область: \(realm)"
        } else {
            alert.informativeText = "Сервер запрашивает имя пользователя и пароль."
        }
        alert.accessoryView = fields
        alert.addButton(withTitle: "Войти")
        alert.addButton(withTitle: "Отмена")

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

        switch navigationSchemePolicy.disposition(for: url) {
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
        alert.messageText = "Открыть ссылку в другом приложении?"
        alert.informativeText = "Схема: \(scheme)\n\(url.absoluteString)"
        alert.addButton(withTitle: "Открыть")
        alert.addButton(withTitle: "Отмена")
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
        alert.messageText = webView.url?.host ?? "Веб-страница"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
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
        alert.messageText = webView.url?.host ?? "Веб-страница"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
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
        alert.messageText = frame.request.url?.host ?? webView.url?.host ?? "Веб-страница"
        alert.informativeText = prompt
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
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
