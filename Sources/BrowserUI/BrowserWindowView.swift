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

            if model.isSidebarVisible {
                SidebarView(model: model)
                    .frame(width: 280)
                    .padding(.leading, 10)
                    .padding(.vertical, 10)
                    .ignoresSafeArea()
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .leading).combined(with: .opacity)
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            hideTask?.cancel()
                        case .ended:
                            scheduleHide()
                        }
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
                    .onTapGesture { model.isOmniboxPresented = false }
                OmniboxOverlay(model: model)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 72)
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
        .background(WindowAccessor(showsTrafficLights: model.isSidebarVisible))
        .focusedSceneValue(\.browserWindowModel, model)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: model.isSidebarVisible)
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

    private var edgeSensor: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: 44)
            .frame(maxHeight: .infinity)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hideTask?.cancel()
                    model.showAutoHideSidebar()
                case .ended:
                    break
                }
            }
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
            if let tab = model.activeTab {
                if let engine = tab.engine, tab.url != nil {
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
                    StartPage(model: model)
                }
            } else {
                StartPage(model: model)
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

private struct StartPage: View {
    let model: BrowserWindowModel

    private let destinations: [(String, String, String)] = [
        ("Apple", "apple.logo", "https://apple.com"),
        ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com"),
        ("Wikipedia", "text.book.closed", "https://wikipedia.org")
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text("Весь интернет — перед вами")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Браузер появляется только тогда, когда нужен")
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.presentOmnibox(clearText: true)
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Введите адрес или запрос")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("⌘L")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(width: 440, height: 48)
                }
                .buttonStyle(.glass)

                HStack(spacing: 12) {
                    ForEach(destinations, id: \.0) { name, symbol, address in
                        Button {
                            guard let url = URL(string: address) else { return }
                            model.navigate(to: url)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: symbol)
                                    .font(.title3)
                                Text(name)
                                    .font(.caption)
                            }
                            .frame(width: 86, height: 58)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(40)
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let showsTrafficLights: Bool

    final class Coordinator {
        var originalButtonFrames: [ObjectIdentifier: NSRect] = [:]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window, coordinator: context.coordinator)
        }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 760, height: 520)

        for type in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            guard let button = window.standardWindowButton(type) else { continue }
            let key = ObjectIdentifier(button)
            let originalFrame = coordinator.originalButtonFrames[key] ?? button.frame
            coordinator.originalButtonFrames[key] = originalFrame
            button.setFrameOrigin(
                NSPoint(
                    x: originalFrame.origin.x + 8,
                    y: originalFrame.origin.y - 8
                )
            )
            button.isHidden = !showsTrafficLights
        }
    }
}
