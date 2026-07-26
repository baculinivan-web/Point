import AppKit
import BrowserCore
import SwiftUI

/// First-run state for the welcome tour.
///
/// The stored value is a version number rather than a flag, so a later release
/// can introduce a new tour by raising `currentVersion`.
@MainActor
public enum BrowserOnboarding {
    private static let completedVersionKey = "CompletedOnboardingVersion"
    private static let currentVersion = 1

    /// Posted when Settings asks for the tour again. The first standard window
    /// to claim the request presents it, so it never opens twice.
    public static let replayRequest = Notification.Name("PointOnboardingReplayRequest")

    private static var isReplayPending = false

    public static var isComplete: Bool {
        UserDefaults.standard.integer(forKey: completedVersionKey) >= currentVersion
    }

    public static func markComplete() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
    }

    /// Brings a browsing window forward and asks it to show the tour again.
    /// Returns `false` when no window took the request, which only happens if
    /// every browsing window is closed.
    @discardableResult
    public static func requestReplay() -> Bool {
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("browser-window") == true
        }) {
            window.makeKeyAndOrderFront(nil)
        }
        isReplayPending = true
        NotificationCenter.default.post(name: replayRequest, object: nil)
        let wasClaimed = !isReplayPending
        isReplayPending = false
        return wasClaimed
    }

    static func claimReplay() -> Bool {
        guard isReplayPending else { return false }
        isReplayPending = false
        return true
    }
}

private enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case split
    case search
    case folders
    case defaultBrowser

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: BrowserLocalization.string("onboarding_welcome_title")
        case .split: BrowserLocalization.string("onboarding_split_title")
        case .search: BrowserLocalization.string("onboarding_search_title")
        case .folders: BrowserLocalization.string("onboarding_folders_title")
        case .defaultBrowser: BrowserLocalization.string("onboarding_default_title")
        }
    }

    var detail: String {
        switch self {
        case .welcome: BrowserLocalization.string("onboarding_welcome_detail")
        case .split: BrowserLocalization.string("onboarding_split_detail")
        case .search: BrowserLocalization.string("onboarding_search_detail")
        case .folders: BrowserLocalization.string("onboarding_folders_detail")
        case .defaultBrowser: BrowserLocalization.string("default_browser_detail")
        }
    }

    var gradient: [Color] {
        switch self {
        case .welcome:
            [Color(red: 0.02, green: 0.80, blue: 0.95), Color(red: 0.17, green: 0.42, blue: 0.95)]
        case .split:
            [Color(red: 0.43, green: 0.36, blue: 0.94), Color(red: 0.69, green: 0.31, blue: 0.88)]
        case .search:
            [Color(red: 1.00, green: 0.48, blue: 0.35), Color(red: 0.96, green: 0.24, blue: 0.55)]
        case .folders:
            [Color(red: 0.07, green: 0.72, blue: 0.51), Color(red: 0.05, green: 0.58, blue: 0.65)]
        case .defaultBrowser:
            [Color(red: 0.13, green: 0.13, blue: 0.15), Color(red: 0.05, green: 0.05, blue: 0.06)]
        }
    }
}

struct OnboardingOverlay: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: OnboardingPage = .welcome
    @State private var isMovingForward = true
    @State private var isDefaultBrowser = false
    @State private var isUpdatingDefaultBrowser = false
    @State private var defaultBrowserError: String?

    private let cardWidth: CGFloat = 660
    private let artworkHeight: CGFloat = 250

    var body: some View {
        ZStack {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .onTapGesture {}

            card
        }
        .onExitCommand(perform: finish)
        .onAppear(perform: refreshDefaultBrowserStatus)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshDefaultBrowserStatus()
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            artwork
            copy
            Spacer(minLength: 12)
            footer
        }
        .frame(width: cardWidth, height: 486)
        .browserGlassSurface(cornerRadius: 28)
        .shadow(color: .black.opacity(0.34), radius: 44, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrowserLocalization.string(
            "onboarding_step_position",
            page.rawValue + 1,
            OnboardingPage.allCases.count
        ))
    }

    private var artwork: some View {
        ZStack {
            LinearGradient(
                colors: page.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            OnboardingArtwork(page: page)
                .id(page)
                .transition(artworkTransition)
        }
        .frame(height: artworkHeight)
        .frame(maxWidth: .infinity)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                topTrailingRadius: 28,
                style: .continuous
            )
        )
        .overlay(alignment: .topTrailing) {
            if page != .defaultBrowser {
                Button(BrowserLocalization.string("onboarding_skip"), action: finish)
                    .buttonStyle(OnboardingGhostButtonStyle())
                    .padding(14)
            }
        }
        .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(page.title)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)

            Text(page.detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if page == .defaultBrowser {
                defaultBrowserStatus
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .id(page)
        .transition(.opacity)
    }

    @ViewBuilder
    private var defaultBrowserStatus: some View {
        if isDefaultBrowser {
            Label(
                BrowserLocalization.string("default_browser_current"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.green)
        } else if isUpdatingDefaultBrowser {
            ProgressView()
                .controlSize(.small)
        } else if let defaultBrowserError {
            Text(defaultBrowserError)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            OnboardingPageDots(
                count: OnboardingPage.allCases.count,
                index: page.rawValue
            )

            Spacer(minLength: 12)

            if page != .welcome {
                Button(BrowserLocalization.string("back"), action: goBack)
                    .buttonStyle(OnboardingSecondaryButtonStyle())
            }

            if page == .defaultBrowser, !isDefaultBrowser {
                Button(BrowserLocalization.string("onboarding_not_now"), action: finish)
                    .buttonStyle(OnboardingSecondaryButtonStyle())
            }

            Button(primaryTitle, action: performPrimaryAction)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(isUpdatingDefaultBrowser)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 26)
    }

    private var primaryTitle: String {
        guard page == .defaultBrowser else {
            return BrowserLocalization.string("onboarding_continue")
        }
        return isDefaultBrowser
            ? BrowserLocalization.string("onboarding_start_browsing")
            : BrowserLocalization.string("make_default_browser")
    }

    private var artworkTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset: CGFloat = isMovingForward ? 40 : -40
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: offset)),
            removal: .opacity.combined(with: .offset(x: -offset))
        )
    }

    private func performPrimaryAction() {
        guard page == .defaultBrowser else {
            advance()
            return
        }
        guard !isDefaultBrowser else {
            finish()
            return
        }
        makeDefaultBrowser()
    }

    private func advance() {
        guard let next = OnboardingPage(rawValue: page.rawValue + 1) else {
            finish()
            return
        }
        isMovingForward = true
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.26)) {
            page = next
        }
    }

    private func goBack() {
        guard let previous = OnboardingPage(rawValue: page.rawValue - 1) else { return }
        isMovingForward = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.26)) {
            page = previous
        }
    }

    private func finish() {
        BrowserOnboarding.markComplete()
        onFinish()
    }

    private func refreshDefaultBrowserStatus() {
        isDefaultBrowser = DefaultBrowserService.isDefaultBrowser()
    }

    private func makeDefaultBrowser() {
        defaultBrowserError = nil
        isUpdatingDefaultBrowser = true
        DefaultBrowserService.makeDefaultBrowser { error in
            isUpdatingDefaultBrowser = false
            isDefaultBrowser = DefaultBrowserService.isDefaultBrowser()
            if let error {
                defaultBrowserError = error.localizedDescription
            } else if !isDefaultBrowser {
                defaultBrowserError = BrowserLocalization.string(
                    "check_default_browser_settings"
                )
            }
        }
    }
}

// MARK: - Controls

private struct OnboardingPageDots: View {
    let count: Int
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { position in
                Capsule()
                    .fill(Color.primary.opacity(position == index ? 0.75 : 0.16))
                    .frame(width: position == index ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: index)
        .accessibilityHidden(true)
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.78 : 1),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.10 : 0),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}

private struct OnboardingGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                Color.black.opacity(configuration.isPressed ? 0.34 : 0.20),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}

// MARK: - Artwork

private struct OnboardingArtwork: View {
    let page: OnboardingPage

    var body: some View {
        switch page {
        case .welcome: WelcomeArtwork()
        case .split: SplitArtwork()
        case .search: SearchArtwork()
        case .folders: FoldersArtwork()
        case .defaultBrowser: DefaultBrowserArtwork()
        }
    }
}

private struct WelcomeArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFloating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.34), .clear],
                        center: .center,
                        startRadius: 8,
                        endRadius: 130
                    )
                )
                .frame(width: 260, height: 260)

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 116, height: 116)
                .shadow(color: .black.opacity(0.26), radius: 22, y: 12)
                .offset(y: isFloating ? -6 : 4)
        }
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                isFloating = true
            }
        }
    }
}

private struct SplitArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ratio: Double = 0.5

    /// 428 window − 96 sidebar − 8 trailing inset − 9 divider.
    private let paneSpace: CGFloat = 315

    var body: some View {
        MockWindowFrame(width: 428, height: 194) {
            HStack(spacing: 0) {
                MockPage(accent: Color(red: 0.24, green: 0.51, blue: 0.96))
                    .frame(width: paneSpace * ratio)

                MockSplitDivider()

                ZStack {
                    MockPage(accent: Color(red: 0.86, green: 0.34, blue: 0.62))
                    MockDraggedTab()
                }
                .frame(width: paneSpace * (1 - ratio))
            }
        }
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                ratio = 0.62
            }
        }
    }
}

private struct SearchArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectionIndex = 0

    private let engines: [SearchEngine] = [.duckDuckGo, .google, .perplexity, .chatGPT]

    var body: some View {
        VStack(spacing: 12) {
            composer
            menu
        }
        .padding(.top, 26)
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1600))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectionIndex = (selectionIndex + 1) % engines.count
                }
            }
        }
    }

    private var selectedEngine: SearchEngine {
        engines[selectionIndex]
    }

    private var composer: some View {
        HStack(spacing: 12) {
            SearchEngineIcon(searchEngine: selectedEngine, size: 24)
                .padding(5)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                }
                .id(selectedEngine)
                .transition(.opacity.combined(with: .scale(scale: 0.86)))

            Text(BrowserLocalization.string("address_or_search_placeholder"))
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Capsule()
                .fill(Color.accentColor.opacity(0.75))
                .frame(width: 2, height: 20)
        }
        .padding(.horizontal, 14)
        .frame(width: 392, height: 54)
        .background(MockSurface(cornerRadius: 15))
        .shadow(color: .black.opacity(0.20), radius: 16, y: 8)
    }

    private var menu: some View {
        VStack(spacing: 1) {
            ForEach(Array(engines.enumerated()), id: \.element.id) { index, engine in
                HStack(spacing: 9) {
                    SearchEngineIcon(searchEngine: engine, size: 16)
                    Text(engine.displayName)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(index == selectionIndex ? 1 : 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    if index == selectionIndex {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 214)
        .background(MockSurface(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
        .frame(width: 392, alignment: .leading)
        .padding(.leading, 4)
    }
}

private struct FoldersArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MockFolderRow(
                title: BrowserLocalization.string("work"),
                isExpanded: isExpanded,
                tint: Color(red: 0.24, green: 0.51, blue: 0.96)
            )

            if isExpanded {
                MockTabRow(tint: Color(red: 0.95, green: 0.35, blue: 0.28), width: 118, indent: 22)
                MockTabRow(tint: Color(red: 0.20, green: 0.68, blue: 0.44), width: 96, indent: 22)
            }

            MockFolderRow(
                title: BrowserLocalization.string("study"),
                isExpanded: false,
                tint: Color(red: 0.86, green: 0.55, blue: 0.16)
            )
            MockFolderRow(
                title: BrowserLocalization.string("travel"),
                isExpanded: false,
                tint: Color(red: 0.55, green: 0.40, blue: 0.92)
            )

            MockTabRow(tint: Color(red: 0.36, green: 0.62, blue: 0.92), width: 128, indent: 0)
        }
        .padding(12)
        .frame(width: 252, alignment: .leading)
        .background(MockSurface(cornerRadius: 16))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isExpanded)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2400))
                guard !Task.isCancelled else { return }
                isExpanded.toggle()
            }
        }
    }
}

private struct DefaultBrowserArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(verbatim: "https://")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 78, height: 7)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(.white.opacity(0.10), in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 1) }

            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.22), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 76
                        )
                    )
                    .frame(width: 150, height: 150)
                    .scaleEffect(isPulsing ? 1.06 : 0.94)

                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
            .frame(height: 96)
        }
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Mock building blocks

/// Neutral panel that reads as a Point surface on top of the artwork gradient.
private struct MockSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct MockWindowFrame<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            MockSidebarStrip()
                .frame(width: 96)

            content
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 10,
                        bottomLeadingRadius: 10,
                        style: .continuous
                    )
                )
                .padding(.vertical, 8)
                .padding(.trailing, 8)
        }
        .frame(width: width, height: height)
        .background(MockSurface(cornerRadius: 16))
        .shadow(color: .black.opacity(0.24), radius: 22, y: 11)
    }
}

private struct MockSidebarStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 4)

            MockTabRow(tint: Color(red: 0.24, green: 0.51, blue: 0.96), width: 58, indent: 0)
            MockTabRow(tint: Color(red: 0.86, green: 0.34, blue: 0.62), width: 46, indent: 0)
            MockTabRow(tint: Color(red: 0.20, green: 0.68, blue: 0.44), width: 52, indent: 0)

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MockTabRow: View {
    let tint: Color
    let width: CGFloat
    let indent: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tint)
                .frame(width: 11, height: 11)
            Capsule()
                .fill(Color.primary.opacity(0.16))
                .frame(width: width, height: 7)
            Spacer(minLength: 0)
        }
        .padding(.leading, indent)
        .frame(height: 22)
    }
}

private struct MockFolderRow: View {
    let title: String
    let isExpanded: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }
}

/// A tiny stand-in web page: a colored hero band over a few text lines.
private struct MockPage: View {
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LinearGradient(
                colors: [accent, accent.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 46)

            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color.primary.opacity(0.22)).frame(width: 78, height: 7)
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 5)
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 5)
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 64, height: 5)
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct MockSplitDivider: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1)
            Capsule()
                .fill(Color.primary.opacity(0.38))
                .frame(width: 3, height: 26)
        }
        .frame(width: 9)
    }
}

/// The tab chip that shows how a split is made: drag a tab onto a page.
private struct MockDraggedTab: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(red: 0.86, green: 0.34, blue: 0.62))
                    .frame(width: 11, height: 11)
                Capsule()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 52, height: 7)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(MockSurface(cornerRadius: 8))
            .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
            .rotationEffect(.degrees(-3))

            Image(systemName: "cursorarrow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(x: 10, y: 12)
        }
    }
}
