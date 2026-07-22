import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

public struct BrowserWindowView: View {
    @Bindable private var model: BrowserWindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var hideTask: Task<Void, Never>?
    @State private var dismissedDownloadIndicators: Set<UUID> = []
    @State private var isFullScreen = false

    public init(model: BrowserWindowModel) {
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            WebSurface(model: model)
                .padding(.leading, model.sidebarMode == .pinned ? 300 : 0)
                .ignoresSafeArea()

            if model.sidebarMode == .autoHide {
                edgeSensor
            }

            SidebarView(model: model, isFullScreen: isFullScreen)
                .frame(width: 280)
                .padding(.leading, 10)
                .padding(.vertical, 10)
                .ignoresSafeArea()
                .offset(x: sidebarOffset)
                .opacity(model.isSidebarVisible ? 1 : 0)
                .allowsHitTesting(model.isSidebarVisible)
                .accessibilityHidden(!model.isSidebarVisible)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        hideTask?.cancel()
                    case .ended:
                        scheduleHide()
                    }
                }

            if let tab = model.activeTab, tab.isLoading {
                LoadingBar(progress: tab.progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if let download = indicatorDownload {
                DownloadProgressBubble(download: download) {
                    dismissedDownloadIndicators.insert(download.id)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, model.sidebarMode == .pinned ? 314 : 14)
                .padding(.top, 14)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .zIndex(4)
            }

            if let prompt = model.mediaPermissionPrompt {
                MediaPermissionOverlay(prompt: prompt) { action in
                    model.resolveMediaPermission(action)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 72)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(6)
            }

            if model.isOmniboxPresented {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissOmnibox() }
                OmniboxOverlay(model: model)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: model.isComposingNewTab ? .center : .top
                    )
                    .padding(.top, model.isComposingNewTab ? 0 : 72)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if model.isFindPresented {
                FindOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 14)
                    .padding(.trailing, 14)
            }

            if model.isSitePermissionsPresented {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissSitePermissions() }
                    .zIndex(8)

                SitePermissionsOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(9)
            }

            if model.isBrowsingHistoryPresented {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissBrowsingHistory() }
                    .zIndex(10)

                BrowsingHistoryOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(11)
            }

            if model.isClearBrowsingDataPresented {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissClearBrowsingData() }
                    .zIndex(12)

                ClearBrowsingDataOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(13)
            }

        }
        .frame(minWidth: 760, minHeight: 520)
        .background(
            WindowAccessor(
                showsTrafficLights: model.isSidebarVisible,
                isFullScreen: $isFullScreen
            )
        )
        .focusedSceneValue(\.browserWindowModel, model)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: model.isSidebarVisible
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.isOmniboxPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: indicatorDownload?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.mediaPermissionPrompt?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.isSitePermissionsPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.isBrowsingHistoryPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.isClearBrowsingDataPresented)
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActive(phase == .active)
        }
        .onDisappear {
            model.stopLifecycleMonitoring()
        }
    }

    private var indicatorDownload: DownloadItem? {
        model.downloadManager.items.first { item in
            item.state.isActive && !dismissedDownloadIndicators.contains(item.id)
        }
    }

    private var sidebarOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        return model.isSidebarVisible ? 0 : -300
    }

    private var edgeSensor: some View {
        EdgeHoverSensor {
            hideTask?.cancel()
            model.showAutoHideSidebar()
        }
            .frame(width: 36)
            .frame(maxHeight: .infinity)
            .onTapGesture {
                model.showAutoHideSidebar()
            }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            model.hideAutoHideSidebar()
        }
    }
}

private struct EdgeHoverSensor: NSViewRepresentable {
    let onMouseEntered: @MainActor () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMouseEntered = onMouseEntered
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMouseEntered = onMouseEntered
    }

    @MainActor
    final class TrackingView: NSView {
        var onMouseEntered: (@MainActor () -> Void)?
        private var edgeTrackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let edgeTrackingArea {
                removeTrackingArea(edgeTrackingArea)
            }

            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            edgeTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onMouseEntered?()
        }
    }
}

private struct DownloadProgressBubble: View {
    let download: DownloadItem
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false
    @State private var rotates = false

    var body: some View {
        Button(action: onDismiss) {
            ZStack {
                glassCore
                progressRing

                Image(systemName: isHovering ? "xmark" : "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Скрыть индикатор загрузки")
        .accessibilityLabel("Загрузка \(download.suggestedFilename), \(progressLabel)")
        .task(id: download.id) {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                rotates = true
            }
        }
    }

    @ViewBuilder
    private var glassCore: some View {
        let core = Circle()
            .fill(.clear)
            .frame(width: 40, height: 40)

        if reduceTransparency {
            core
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .overlay(Circle().stroke(.separator, lineWidth: 1))
        } else if #available(macOS 26, *) {
            core.glassEffect(.regular.interactive(), in: .circle)
        } else {
            core.background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    private var progressRing: some View {
        Circle()
            .stroke(.primary.opacity(0.16), lineWidth: 2)
            .frame(width: 46, height: 46)

        if let fraction = download.fractionCompleted {
            Circle()
                .trim(from: 0, to: max(0.025, min(fraction, 1)))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 46, height: 46)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.16),
                    value: fraction
                )
        } else {
            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(rotates ? 270 : -90))
                .frame(width: 46, height: 46)
        }
    }

    private var progressLabel: String {
        guard let fraction = download.fractionCompleted else { return "выполняется" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct WebSurface: View {
    let model: BrowserWindowModel

    var body: some View {
        Group {
            if let tab = model.activeTab,
               let engine = tab.engine {
                WKWebViewHost(
                    webView: engine.webView,
                    onSwipeBack: { [weak model] in
                        model?.handleNavigationSwipe(.back) ?? false
                    },
                    onSwipeForward: { [weak model] in
                        model?.handleNavigationSwipe(.forward) ?? false
                    }
                )
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct LoadingBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.16))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(
                        width: geometry.size.width * min(max(progress, 0), 1)
                    )
            }
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let showsTrafficLights: Bool
    @Binding var isFullScreen: Bool

    @MainActor
    final class Coordinator: NSObject {
        var originalButtonFrames: [ObjectIdentifier: NSRect] = [:]
        weak var window: NSWindow?
        var showsTrafficLights = true
        var onFullScreenChange: (@MainActor (Bool) -> Void)?
        var lastReportedFullScreen: Bool?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func configure(
            _ window: NSWindow?,
            showsTrafficLights: Bool,
            onFullScreenChange: @escaping @MainActor (Bool) -> Void
        ) {
            guard let window else { return }
            self.showsTrafficLights = showsTrafficLights
            self.onFullScreenChange = onFullScreenChange

            if self.window !== window {
                if let currentWindow = self.window {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: NSWindow.didEnterFullScreenNotification,
                        object: currentWindow
                    )
                    NotificationCenter.default.removeObserver(
                        self,
                        name: NSWindow.didExitFullScreenNotification,
                        object: currentWindow
                    )
                }
                self.window = window
                lastReportedFullScreen = nil
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(fullScreenStateDidChange),
                    name: NSWindow.didEnterFullScreenNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(fullScreenStateDidChange),
                    name: NSWindow.didExitFullScreenNotification,
                    object: window
                )
            }

            applyWindowConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.applyWindowConfiguration()
            }
        }

        @objc private func fullScreenStateDidChange(_ notification: Notification) {
            applyWindowConfiguration()
        }

        private func applyWindowConfiguration() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 760, height: 520)

            let isFullScreen = window.styleMask.contains(.fullScreen)
            if lastReportedFullScreen != isFullScreen {
                lastReportedFullScreen = isFullScreen
                onFullScreenChange?(isFullScreen)
            }

            for type in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ] {
                guard let button = window.standardWindowButton(type) else { continue }
                let key = ObjectIdentifier(button)
                let originalFrame = originalButtonFrames[key] ?? button.frame
                originalButtonFrames[key] = originalFrame
                if !isFullScreen {
                    button.setFrameOrigin(
                        NSPoint(
                            x: originalFrame.origin.x + 14,
                            y: originalFrame.origin.y - 12
                        )
                    )
                }

                // In full screen AppKit owns the traffic-light reveal on top-edge hover.
                button.isHidden = isFullScreen ? false : !showsTrafficLights
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.configure(
                view.window,
                showsTrafficLights: showsTrafficLights,
                onFullScreenChange: { isFullScreen = $0 }
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.configure(
                nsView.window,
                showsTrafficLights: showsTrafficLights,
                onFullScreenChange: { isFullScreen = $0 }
            )
        }
    }
}
