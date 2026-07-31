import AppKit
import BrowserAI
import BrowserAutomation
import BrowserCore
import BrowserEngine
import SwiftUI

public enum BrowserUpdateDownloadState: Equatable, Sendable {
    case idle
    case downloading(progress: Double?)
    case ready
    case failed
}

public struct BrowserWindowView: View {
    @Bindable private var model: BrowserWindowModel
    @Binding private var isOnboardingPresented: Bool
    private let availableUpdate: AvailableRelease?
    private let updateDownloadState: BrowserUpdateDownloadState
    private let onInstallUpdate: (AvailableRelease) -> Void
    private let onCancelUpdateDownload: () -> Void
    private let onRevealDownloadedUpdate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var hideTask: Task<Void, Never>?
    @State private var dismissedDownloadIndicators: Set<UUID> = []
    @State private var isFullScreen = false
    @State private var hostWindow: NSWindow?
    @State private var isUpdateDetailsPresented = false

    public init(
        model: BrowserWindowModel,
        isOnboardingPresented: Binding<Bool> = .constant(false),
        availableUpdate: AvailableRelease? = nil,
        updateDownloadState: BrowserUpdateDownloadState = .idle,
        onInstallUpdate: @escaping (AvailableRelease) -> Void = { _ in },
        onCancelUpdateDownload: @escaping () -> Void = {},
        onRevealDownloadedUpdate: @escaping () -> Void = {}
    ) {
        self.model = model
        _isOnboardingPresented = isOnboardingPresented
        self.availableUpdate = availableUpdate
        self.updateDownloadState = updateDownloadState
        self.onInstallUpdate = onInstallUpdate
        self.onCancelUpdateDownload = onCancelUpdateDownload
        self.onRevealDownloadedUpdate = onRevealDownloadedUpdate
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            WebSurface(model: model)
                .padding(.leading, model.sidebarMode == .pinned ? 300 : 0)
                .padding(.trailing, aiChatPanelWidth)
                .clipShape(
                    LeadingRoundedRectangle(
                        radius: model.sidebarMode == .pinned ? 18 : 0
                    )
                )
                .ignoresSafeArea()

            if model.isAIChatPanelVisible {
                AIChatPanelView(model: model)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .trailing
                    )
                    .ignoresSafeArea()
                    .transition(.move(edge: .trailing))
                    .zIndex(6)
            }

            if model.sidebarMode == .autoHide, model.previewTab == nil {
                edgeSensor
            }

            SidebarView(
                model: model,
                isFullScreen: isFullScreen,
                availableUpdate: availableUpdate,
                updateDownloadState: updateDownloadState,
                onCancelUpdateDownload: onCancelUpdateDownload
            ) {
                isUpdateDetailsPresented = true
            }
                .frame(width: model.sidebarMode == .pinned ? 300 : 280)
                .padding(.leading, model.sidebarMode == .pinned ? 0 : 10)
                .padding(.vertical, model.sidebarMode == .pinned ? 0 : 10)
                .ignoresSafeArea()
                .offset(x: sidebarOffset)
                .opacity(model.isSidebarVisible ? 1 : 0)
                .allowsHitTesting(model.isSidebarVisible && model.previewTab == nil)
                .accessibilityHidden(!model.isSidebarVisible || model.previewTab != nil)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        hideTask?.cancel()
                    case .ended:
                        scheduleHide()
                    }
                }

            if model.previewTab != nil {
                WebPreviewOverlay(model: model)
                    .ignoresSafeArea()
                    .zIndex(30)
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

            if let message = model.toastMessage {
                CopyToast(message: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, isFullScreen ? 24 : 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
                    .zIndex(20)
            }

            if let prompt = model.mediaPermissionPrompt {
                MediaPermissionOverlay(prompt: prompt) { action in
                    model.resolveMediaPermission(action)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 72)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(40)
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
                    .padding(.trailing, 14 + aiChatPanelWidth)
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

            if isOnboardingPresented {
                OnboardingOverlay {
                    isOnboardingPresented = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(60)
            }

            if let availableUpdate, isUpdateDetailsPresented {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { isUpdateDetailsPresented = false }
                    .zIndex(70)

                ReleaseUpdateOverlay(
                    release: availableUpdate,
                    downloadState: updateDownloadState,
                    onUpdate: {
                        onInstallUpdate(availableUpdate)
                        isUpdateDetailsPresented = false
                    },
                    onCancelDownload: onCancelUpdateDownload,
                    onRevealDownloadedUpdate: onRevealDownloadedUpdate,
                    onClose: { isUpdateDetailsPresented = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(71)
            }

        }
        .frame(minWidth: 760, minHeight: 520)
        .background(
            WindowAccessor(
                showsTrafficLights: model.isSidebarVisible,
                isPrivate: model.isPrivate,
                isFullScreen: $isFullScreen,
                hostWindow: $hostWindow
            )
        )
        .focusedSceneValue(\.browserWindowModel, model)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: model.isSidebarVisible
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: model.isAIChatPanelVisible
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.isOmniboxPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: indicatorDownload?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.mediaPermissionPrompt?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.isSitePermissionsPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.isBrowsingHistoryPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.isClearBrowsingDataPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.toastMessage)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isOnboardingPresented)
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActive(phase == .active)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: BrowserOnboarding.replayRequest)
        ) { _ in
            guard !model.isPrivate, !isOnboardingPresented else { return }
            guard BrowserOnboarding.claimReplay() else { return }
            isOnboardingPresented = true
            // The request comes from Settings, which is in front of this window.
            NSApp.activate()
            hostWindow?.makeKeyAndOrderFront(nil)
        }
        .onDisappear {
            model.stopLifecycleMonitoring()
        }
    }

    /// Reading the observable width here keeps the page inset in sync while
    /// the panel edge is dragged.
    private var aiChatPanelWidth: CGFloat {
        model.isAIChatPanelVisible ? CGFloat(AIChatSettings.shared.panelWidth) : 0
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

private struct ReleaseUpdateOverlay: View {
    let release: AvailableRelease
    let downloadState: BrowserUpdateDownloadState
    let onUpdate: () -> Void
    let onCancelDownload: () -> Void
    let onRevealDownloadedUpdate: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(BrowserLocalization.string(
                        "update_details_title",
                        release.version.description
                    ))
                    .font(.headline)
                    Text(BrowserLocalization.string("release_notes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(BrowserLocalization.string("close"))
            }
            .padding(.horizontal, 20)
            .frame(height: 64)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    downloadStatusCard

                    if release.releaseNotes.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty {
                        ContentUnavailableView(
                            BrowserLocalization.string("release_notes"),
                            systemImage: "note.text",
                            description: Text(BrowserLocalization.string(
                                "release_notes_unavailable"
                            ))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(32)
                    } else {
                        ChatMarkdownView(text: release.releaseNotes)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button(BrowserLocalization.string("later"), action: onClose)
                Spacer()
                switch downloadState {
                case .idle, .failed:
                    Button(BrowserLocalization.string("update"), action: onUpdate)
                        .buttonStyle(.borderedProminent)
                case .downloading:
                    Button(
                        BrowserLocalization.string("cancel"),
                        role: .destructive,
                        action: onCancelDownload
                    )
                case .ready:
                    Button(
                        BrowserLocalization.string("update_show_in_finder"),
                        action: onRevealDownloadedUpdate
                    )
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 62)
        }
        .frame(width: 500, height: 470)
        .browserGlassSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.2), radius: 30, y: 16)
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrowserLocalization.string(
            "update_details_title",
            release.version.description
        ))
    }

    @ViewBuilder
    private var downloadStatusCard: some View {
        switch downloadState {
        case .idle:
            EmptyView()
        case let .downloading(progress):
            VStack(alignment: .leading, spacing: 8) {
                Text(downloadProgressText(progress))
                    .font(.subheadline.weight(.semibold))
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        case .ready:
            Label {
                Text(BrowserLocalization.string("update_ready_instructions"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.subheadline)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        case .failed:
            Label(
                BrowserLocalization.string("update_download_failed"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(.red)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func downloadProgressText(_ progress: Double?) -> String {
        guard let progress else {
            return BrowserLocalization.string("update_downloading_title")
        }
        return BrowserLocalization.string(
            "update_downloading_percent",
            Int((progress * 100).rounded())
        )
    }
}

private struct LeadingRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let cornerRadius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct CopyToast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
            .accessibilityAddTraits(.isStaticText)
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
        .help(BrowserLocalization.string("hide_download_indicator"))
        .accessibilityLabel(BrowserLocalization.string(
            "download_progress_label",
            download.suggestedFilename,
            progressLabel
        ))
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
        guard let fraction = download.fractionCompleted else {
            return BrowserLocalization.string("in_progress")
        }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct WebSurface: View {
    let model: BrowserWindowModel

    var body: some View {
        ZStack {
            if let folderID = model.activeSplitFolderID,
               model.activeSplitTabs.count == 2 {
                SplitWebSurface(
                    model: model,
                    folderID: folderID,
                    tabs: model.activeSplitTabs,
                    ratio: model.activeSplitRatio,
                    blockedLeadingWidth: blockedWebInteractionWidth
                )
            } else {
                singlePage
            }

            if let side = model.splitDropSide {
                SplitDropPreview(side: side)
                    .padding(.leading, blockedWebInteractionWidth)
            }
        }
        .background {
            // The sidebar drag runs as a SwiftUI gesture rather than an AppKit drag
            // session, because the WKWebView swallows drops before they reach us.
            // It needs this frame to tell which pane the pointer is over.
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.frame(in: .global), initial: true) {
                    model.webSurfaceFrame = proxy.frame(in: .global)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var singlePage: some View {
        if let tab = model.activeTab,
           let engine = tab.engine {
            WKWebViewHost(
                webView: engine.webView,
                blockedLeadingWidth: blockedWebInteractionWidth,
                onSwipeBack: { [weak model] in
                    model?.handleNavigationSwipe(.back) ?? false
                },
                onSwipeForward: { [weak model] in
                    model?.handleNavigationSwipe(.forward) ?? false
                }
            )

            // Sits above the page, never inside it: the site must not be able
            // to see, restyle, or counterfeit the "an agent is driving" cue.
            // Deliberately not inset for an overlaying sidebar: the page keeps
            // its full width there, and insetting the halo made it look like
            // the page had been resized.
            AgentControlOverlay(activity: model.agentActivity, tabID: tab.id)

            if tab.isShowingRestorationPlaceholder {
                RestoringTabPlaceholder()
                    .transition(.opacity)
            }
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }

    private var blockedWebInteractionWidth: CGFloat {
        model.sidebarMode == .autoHide && model.isSidebarVisible ? 300 : 0
    }
}

private struct SplitWebSurface: View {
    let model: BrowserWindowModel
    let folderID: TabFolderID
    let tabs: [BrowserTab]
    let ratio: Double
    let blockedLeadingWidth: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let dividerWidth: CGFloat = 10
            let contentWidth = max(0, geometry.size.width - dividerWidth)
            let leftWidth = contentWidth * ratio

            HStack(spacing: 0) {
                SplitWebPane(
                    tab: tabs[0],
                    blockedLeadingWidth: blockedLeadingWidth,
                    agentActivity: model.agentActivity
                )
                .frame(width: leftWidth)

                SplitResizeHandle(
                    ratio: ratio,
                    availableWidth: contentWidth,
                    onChange: { value in
                        model.setSplitRatio(value, for: folderID, persistChange: false)
                    },
                    onCommit: { value in
                        model.setSplitRatio(value, for: folderID)
                    }
                )
                .frame(width: dividerWidth)

                SplitWebPane(
                    tab: tabs[1],
                    blockedLeadingWidth: 0,
                    agentActivity: model.agentActivity
                )
                    .frame(width: max(0, contentWidth - leftWidth))
            }
        }
    }
}

private struct SplitWebPane: View {
    let tab: BrowserTab
    let blockedLeadingWidth: CGFloat
    var agentActivity: AgentActivityCenter?

    var body: some View {
        ZStack {
            if let engine = tab.engine {
                WKWebViewHost(
                    webView: engine.webView,
                    blockedLeadingWidth: blockedLeadingWidth,
                    onSwipeBack: { false },
                    onSwipeForward: { false }
                )

                if let agentActivity {
                    AgentControlOverlay(activity: agentActivity, tabID: tab.id)
                }
            } else {
                Color(nsColor: .textBackgroundColor)
            }

            if tab.isShowingRestorationPlaceholder {
                RestoringTabPlaceholder()
                    .transition(.opacity)
            }
        }
        .clipped()
    }
}

private struct SplitResizeHandle: View {
    let ratio: Double
    let availableWidth: CGFloat
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var startRatio: Double?
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Rectangle().fill(.separator.opacity(isDragging ? 0.95 : 0.55))
                .frame(width: isDragging ? 2 : 1)
            Capsule()
                .fill(.secondary.opacity(isDragging ? 0.7 : 0.32))
                .frame(width: 3, height: 34)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if !hovering && !isDragging { isDragging = false }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if startRatio == nil { startRatio = ratio }
                    isDragging = true
                    guard let startRatio, availableWidth > 0 else { return }
                    onChange(startRatio + value.translation.width / availableWidth)
                }
                .onEnded { value in
                    let resolved = (startRatio ?? ratio)
                        + value.translation.width / max(availableWidth, 1)
                    onCommit(resolved)
                    startRatio = nil
                    isDragging = false
                }
        )
        .accessibilityLabel("Resize split view")
        .accessibilityHint("Drag left or right to change the page widths")
    }
}

private struct SplitDropPreview: View {
    let side: SplitPaneSide

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 6) {
                SplitDropZone(isHighlighted: side == .left)
                SplitDropZone(isHighlighted: side == .right)
            }
            .padding(18)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.black.opacity(0.16))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

private struct SplitDropZone: View {
    let isHighlighted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isHighlighted ? Color.accentColor.opacity(0.28) : .black.opacity(0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isHighlighted ? Color.accentColor.opacity(0.95) : .white.opacity(0.24),
                        lineWidth: isHighlighted ? 2 : 1
                    )
            }
    }
}

private struct WebPreviewOverlay: View {
    let model: BrowserWindowModel

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = model.sidebarMode == .pinned ? 300.0 : 0.0
            let availableWidth = max(0, geometry.size.width - sidebarWidth)
            let plateWidth = max(0, availableWidth - 48)
            let plateHeight = max(0, geometry.size.height - 48)
            let previewWidth = max(0, plateWidth - 16)
            let previewHeight = max(0, plateHeight - 16)

            ZStack {
                Color.black.opacity(0.22)

                if let preview = model.previewTab,
                   let engine = preview.engine {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(.clear)
                            .browserGlassSurface(cornerRadius: 26)

                        WKWebViewHost(
                            webView: engine.webView,
                            onSwipeBack: { false },
                            onSwipeForward: { false }
                        )
                        .frame(width: previewWidth, height: previewHeight)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 19, style: .continuous)
                        )
                        .padding(8)

                        PreviewControls(
                            onClose: model.dismissPreview,
                            onExpand: model.expandPreviewToTab
                        )
                        .padding(14)
                    }
                    .frame(
                        width: plateWidth,
                        height: plateHeight
                    )
                    .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(width: availableWidth, height: geometry.size.height)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct PreviewControls: View {
    let onClose: () -> Void
    let onExpand: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                PreviewGlassButton(
                    symbol: "xmark",
                    help: BrowserLocalization.string("close_preview"),
                    action: onClose
                )
                PreviewGlassButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    help: BrowserLocalization.string("expand_preview"),
                    action: onExpand
                )
            }
        }
    }
}

private struct PreviewGlassButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .previewGlassBubble(reduceTransparency: reduceTransparency)
    }
}

private extension View {
    @ViewBuilder
    func previewGlassBubble(reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .overlay(Circle().stroke(.separator, lineWidth: 1))
        } else if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct RestoringTabPlaceholder: View {
    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)

                Text(BrowserLocalization.string("restoring_unloaded_tab"))
                    .font(.headline)

                Text(BrowserLocalization.string("restoring_unloaded_tab_detail"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .browserGlassSurface(cornerRadius: 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
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
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let showsTrafficLights: Bool
    let isPrivate: Bool
    @Binding var isFullScreen: Bool
    @Binding var hostWindow: NSWindow?

    @MainActor
    final class Coordinator: NSObject {
        var originalButtonFrames: [ObjectIdentifier: NSRect] = [:]
        weak var window: NSWindow?
        var showsTrafficLights = true
        var isPrivate = false
        var onFullScreenChange: (@MainActor (Bool) -> Void)?
        var lastReportedFullScreen: Bool?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func configure(
            _ window: NSWindow?,
            showsTrafficLights: Bool,
            isPrivate: Bool,
            onFullScreenChange: @escaping @MainActor (Bool) -> Void
        ) {
            guard let window else { return }
            self.showsTrafficLights = showsTrafficLights
            self.isPrivate = isPrivate
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
            // Glass surfaces sample what is behind the window, so the desktop
            // shows through the chat panel and the sidebar's floating edges.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.minSize = NSSize(width: 760, height: 520)
            window.title = isPrivate
                ? BrowserLocalization.string("private_window_title")
                : "Point"
            window.representedURL = nil

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
                isPrivate: isPrivate,
                onFullScreenChange: { isFullScreen = $0 }
            )
            if hostWindow !== view.window {
                hostWindow = view.window
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.configure(
                nsView.window,
                showsTrafficLights: showsTrafficLights,
                isPrivate: isPrivate,
                onFullScreenChange: { isFullScreen = $0 }
            )
            if hostWindow !== nsView.window {
                hostWindow = nsView.window
            }
        }
    }
}
