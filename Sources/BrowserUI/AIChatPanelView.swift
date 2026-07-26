import AppKit
import BrowserAI
import BrowserCore
import SwiftUI

enum AIChatLayout {
    /// Width of the drag strip along the panel's leading edge.
    static let resizeHandleWidth: CGFloat = 8
}

/// The chat panel docked to the trailing edge of a browser window.
///
/// The whole panel is a pane of tinted glass, so the desktop shows through it,
/// and the transcript scrolls beneath a floating glass composer.
struct AIChatPanelView: View {
    let model: BrowserWindowModel

    @Bindable private var settings = AIChatSettings.shared
    @State private var widthAtDragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle

            VStack(spacing: 0) {
                AIChatHeaderView(
                    session: model.aiChat,
                    onDetach: { model.detachAIChat() },
                    onClose: { model.dismissAIChat() }
                )
                AIChatConversationView(session: model.aiChat)
            }
        }
        .frame(width: settings.panelWidth)
        .browserTintedGlass(tint: Color.accentColor.opacity(0.05))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrowserLocalization.string("ai_chat_title"))
    }

    /// Dragging the leading edge resizes the panel; the width persists.
    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: AIChatLayout.resizeHandleWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.separator.opacity(0.5))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = widthAtDragStart ?? settings.panelWidth
                        widthAtDragStart = start
                        // Dragging left (negative) widens the trailing panel.
                        settings.panelWidth = start - value.translation.width
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            .accessibilityLabel(BrowserLocalization.string("ai_chat_resize"))
    }
}

// MARK: - Detached window

/// The chat living in its own window after a detach.
public struct AIChatWindowView: View {
    @State private var session: AIChatSession?

    public init(token: UUID?) {
        _session = State(
            initialValue: token.flatMap { AIChatWindowBridge.shared.claim($0) }
        )
    }

    public var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    AIChatHeaderView(
                        session: session,
                        onReattach: {
                            session.isDetached = false
                            session.onReattachRequest?()
                        }
                    )
                    AIChatConversationView(session: session)
                }
                .onDisappear {
                    // Closing the window returns the conversation to the panel.
                    session.isDetached = false
                }
            } else {
                Text(BrowserLocalization.string("ai_chat_detached_placeholder"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 380, idealWidth: 460, minHeight: 460, idealHeight: 660)
    }
}

// MARK: - Header

private struct AIChatHeaderView: View {
    @Bindable var session: AIChatSession
    var onDetach: (() -> Void)?
    var onReattach: (() -> Void)?
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 6) {
            Text(BrowserLocalization.string("ai_chat_title"))
                .font(.callout.weight(.semibold))

            Spacer(minLength: 8)

            historyMenu

            headerButton(
                symbol: "square.and.pencil",
                help: BrowserLocalization.string("ai_chat_new")
            ) {
                session.startNewConversation()
            }
            .disabled(session.isEmpty)

            if let onDetach {
                headerButton(
                    symbol: "macwindow",
                    help: BrowserLocalization.string("ai_chat_detach"),
                    action: onDetach
                )
            }
            if let onReattach {
                headerButton(
                    symbol: "sidebar.trailing",
                    help: BrowserLocalization.string("ai_chat_reattach")
                ) {
                    onReattach()
                    dismiss()
                }
            }
            if let onClose {
                headerButton(
                    symbol: "xmark",
                    help: BrowserLocalization.string("ai_chat_close"),
                    action: onClose
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var historyMenu: some View {
        Menu {
            let history = session.history
            if history.isEmpty {
                Text(BrowserLocalization.string("ai_chat_history_empty"))
            } else {
                ForEach(history) { conversation in
                    Button(conversation.title) {
                        session.open(conversationID: conversation.id)
                    }
                }
                Divider()
                Button(BrowserLocalization.string("ai_chat_history_clear"), role: .destructive) {
                    session.clearHistory()
                }
            }
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 24)
        .help(BrowserLocalization.string("ai_chat_history"))
        .accessibilityLabel(BrowserLocalization.string("ai_chat_history"))
    }

    private func headerButton(
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Conversation

/// Transcript plus composer; shared by the docked panel and detached window.
struct AIChatConversationView: View {
    @Bindable var session: AIChatSession
    @Bindable private var settings = AIChatSettings.shared

    @State private var draft = ""
    @State private var attachments: [AIAttachment] = []
    @State private var composerHeight: CGFloat = 56
    @FocusState private var isInputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if !settings.isConfigured {
                AIChatSetupView()
            } else if session.isEmpty {
                emptyState
            } else {
                transcript
            }

            composerLayer
        }
        .environment(\.openURL, OpenURLAction { url in
            // Links belong in a browser tab, not an external window.
            guard let handler = session.onOpenURL else { return .systemAction }
            handler(url)
            return .handled
        })
        .task {
            await Task.yield()
            isInputFocused = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(BrowserLocalization.string("ai_chat_empty_title"))
                .font(.headline)
            Text(BrowserLocalization.string("ai_chat_empty_message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, composerHeight)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { message in
                        AIChatMessageView(message: message)
                            .id(message.id)
                    }
                    if session.isStreaming {
                        AIChatTypingIndicator()
                    }
                    // Keeps the last message clear of the floating composer.
                    Color.clear
                        .frame(height: composerHeight + 8)
                        .id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: session.messages.count) { scrollToBottom(proxy) }
            .onChange(of: session.messages.last?.text) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// The composer floats above the transcript so content passes under the
    /// glass, which is what the material is for.
    private var composerLayer: some View {
        VStack(spacing: 6) {
            if session.isContextNearlyFull {
                AIChatContextMeter(session: session)
            }
            if let error = session.errorMessage {
                AIChatErrorBanner(message: error) {
                    session.errorMessage = nil
                }
            }
            composer
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) {
                        composerHeight = proxy.size.height
                    }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !attachments.isEmpty {
                AIChatAttachmentStrip(attachments: attachments) { id in
                    attachments.removeAll { $0.id == id }
                }
                .padding(.leading, 3)
            }

            HStack(alignment: .bottom, spacing: 6) {
                attachButton
                inputField
                    // Matches the action button so a single line sits centred.
                    .frame(minHeight: 26)
                actionButton
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .browserTintedGlass(cornerRadius: 20, isInteractive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var attachButton: some View {
        Button {
            let picked = AIChatAttachmentPicker.present(
                allowsImages: settings.supportsImageAttachments
            )
            attachments.append(contentsOf: picked)
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(
            settings.supportsImageAttachments
                ? BrowserLocalization.string("ai_chat_attach")
                : BrowserLocalization.string("ai_chat_attach_text_only")
        )
        .accessibilityLabel(BrowserLocalization.string("ai_chat_attach"))
    }

    private var inputField: some View {
        TextField(
            BrowserLocalization.string("ai_chat_input_placeholder"),
            text: $draft,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.callout)
        .lineLimit(1...7)
        .focused($isInputFocused)
        .onSubmit(sendDraft)
    }

    private var actionButton: some View {
        let isStreaming = session.isStreaming
        let label = isStreaming
            ? BrowserLocalization.string("ai_chat_stop")
            : BrowserLocalization.string("ai_chat_send")

        return Button {
            if isStreaming {
                session.cancelStreaming()
            } else {
                sendDraft()
            }
        } label: {
            Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(actionForeground)
                .frame(width: 26, height: 26)
                .background(actionBackground, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isStreaming && !canSend)
        .help(label)
        .accessibilityLabel(label)
    }

    private var actionForeground: Color {
        if session.isStreaming { return Color(nsColor: .windowBackgroundColor) }
        return canSend ? Color(nsColor: .windowBackgroundColor) : .secondary
    }

    private var actionBackground: Color {
        if session.isStreaming { return .red.opacity(0.9) }
        return canSend ? Color.accentColor : Color.secondary.opacity(0.18)
    }

    private var canSend: Bool {
        guard settings.isConfigured else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    private func sendDraft() {
        guard canSend, !session.isStreaming else { return }
        let text = draft
        let files = attachments
        draft = ""
        attachments = []
        session.send(
            text,
            attachments: files,
            includePageContext: settings.includesPageContext
        )
    }
}

/// Warns as the conversation fills the model's context and offers to compact
/// it. Past the automatic threshold the chat compacts itself before sending.
private struct AIChatContextMeter: View {
    @Bindable var session: AIChatSession

    var body: some View {
        HStack(spacing: 8) {
            if session.isCompacting {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.caption)
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    session.isCompacting
                        ? BrowserLocalization.string("ai_chat_compacting")
                        : BrowserLocalization.string(
                            "ai_chat_context_used",
                            Int(session.contextUsageFraction * 100)
                        )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                ProgressView(value: session.contextUsageFraction)
                    .controlSize(.mini)
                    .tint(tint)
            }

            if !session.isCompacting {
                Button(BrowserLocalization.string("ai_chat_compact")) {
                    session.compact()
                }
                .controlSize(.small)
                .disabled(!session.canCompact)
                .help(BrowserLocalization.string("ai_chat_compact_help"))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .browserTintedGlass(cornerRadius: 13, tint: tint.opacity(0.10))
    }

    private var tint: Color {
        session.contextUsageFraction >= 0.85 ? .orange : .accentColor
    }
}

private struct AIChatErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(BrowserLocalization.string("ai_chat_dismiss_error"))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .browserTintedGlass(cornerRadius: 13, tint: .orange.opacity(0.10))
    }
}

// MARK: - Messages

private struct AIChatMessageView: View {
    let message: AIChatMessage

    var body: some View {
        switch message.role {
        case .notice:
            Label(message.text, systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    AIChatAttachmentStrip(
                        attachments: message.attachments,
                        alignment: .trailing
                    )
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 32)
        case .assistant:
            VStack(alignment: .leading, spacing: 7) {
                if message.toolActivities.count == 1 {
                    AIChatToolActivityView(activity: message.toolActivities[0])
                } else if message.toolActivities.count > 1 {
                    // A turn can fire many tools at once; collapse them so the
                    // answer stays the thing you read first.
                    AIChatToolActivityGroup(activities: message.toolActivities)
                }
                if !message.text.isEmpty {
                    ChatMarkdownView(text: message.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Attachment chips: thumbnails for images, a labelled chip for files.
/// Shown in the composer (removable) and above the sent message.
private struct AIChatAttachmentStrip: View {
    let attachments: [AIAttachment]
    /// Sent messages align with their bubble on the trailing edge; the
    /// composer keeps its chips on the leading edge.
    var alignment: HorizontalAlignment = .leading
    var onRemove: ((UUID) -> Void)?

    var body: some View {
        if alignment == .trailing {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(attachments) { attachment in
                    chip(for: attachment)
                }
            }
            .padding(.trailing, 1)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        chip(for: attachment)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func chip(for attachment: AIAttachment) -> some View {
        Group {
            if attachment.kind == .image, let image = NSImage(data: attachment.data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(attachment.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button {
                    onRemove(attachment.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .accessibilityLabel(
                    BrowserLocalization.string("ai_chat_remove_attachment", attachment.name)
                )
            }
        }
        .help(attachment.name)
    }
}

/// Several tool calls from one turn, shown as a single expandable row.
private struct AIChatToolActivityGroup: View {
    let activities: [AIChatToolActivity]

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    leadingIcon
                    Text(title)
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(BrowserLocalization.string("ai_chat_tools_expand"))
            .accessibilityLabel(title)
            .accessibilityHint(BrowserLocalization.string("ai_chat_tools_expand"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(activities) { activity in
                        AIChatToolActivityView(activity: activity)
                    }
                }
                .padding(.leading, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isExpanded)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if runningCount > 0 {
            ProgressView().controlSize(.mini)
        } else if failureCount > 0 {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
    }

    private var title: String {
        guard runningCount > 0 else {
            return BrowserLocalization.string(
                "ai_chat_tools_collapsed",
                activities.count
            )
        }
        return BrowserLocalization.string(
            "ai_chat_tools_running",
            activities.count - runningCount,
            activities.count
        )
    }

    private var runningCount: Int {
        activities.filter { $0.state == .running }.count
    }

    private var failureCount: Int {
        activities.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
    }
}

private struct AIChatToolActivityView: View {
    let activity: AIChatToolActivity

    var body: some View {
        HStack(spacing: 7) {
            switch activity.state {
            case .running:
                ProgressView()
                    .controlSize(.mini)
            case .finished:
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(title)
                .font(.caption.weight(.medium))
            if !activity.summary.isEmpty {
                Text(activity.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help(helpText)
    }

    private var symbol: String {
        switch activity.name {
        case "web_search": "magnifyingglass"
        case "open_tab": "plus.rectangle.on.rectangle"
        case "read_page": "doc.text.magnifyingglass"
        case "screenshot_page": "camera.viewfinder"
        case "run_python": "chevron.left.forwardslash.chevron.right"
        case "list_tabs": "rectangle.stack"
        case "group_tabs": "folder.badge.plus"
        case "remember": "brain"
        case "recall_memories", "search_memories": "brain.head.profile"
        case "forget_memory": "trash"
        default: "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch activity.name {
        case "web_search": BrowserLocalization.string("ai_tool_web_search")
        case "open_tab": BrowserLocalization.string("ai_tool_open_tab")
        case "read_page": BrowserLocalization.string("ai_tool_read_page")
        case "screenshot_page": BrowserLocalization.string("ai_tool_screenshot")
        case "run_python": BrowserLocalization.string("ai_tool_python")
        case "list_tabs": BrowserLocalization.string("ai_tool_list_tabs")
        case "group_tabs": BrowserLocalization.string("ai_tool_group_tabs")
        case "remember": BrowserLocalization.string("ai_tool_remember")
        case "recall_memories", "search_memories":
            BrowserLocalization.string("ai_tool_recall")
        case "forget_memory": BrowserLocalization.string("ai_tool_forget")
        default: activity.name
        }
    }

    private var helpText: String {
        if case let .failed(message) = activity.state {
            return message
        }
        return activity.summary
    }
}

private struct AIChatTypingIndicator: View {
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase ? 0.25 : 0.9)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(index) * 0.16),
                        value: phase
                    )
            }
        }
        .frame(height: 16)
        .task { phase = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Setup

/// Shown inside the panel until a provider is configured, so setup can be
/// finished without leaving the chat.
struct AIChatSetupView: View {
    @Bindable private var settings = AIChatSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(BrowserLocalization.string("ai_setup_title"))
                        .font(.headline)
                    Text(BrowserLocalization.string("ai_setup_message"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AIProviderSetupControls()

                SettingsLink {
                    Text(BrowserLocalization.string("ai_setup_open_settings"))
                }
                .controlSize(.small)
            }
            .padding(16)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Provider picker plus the credential field or Ollama installer.
/// Shared by the panel setup card, Settings, and the welcome tour.
struct AIProviderSetupControls: View {
    @Bindable private var settings = AIChatSettings.shared
    private let ollama = OllamaRuntime.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                BrowserLocalization.string("ai_settings_provider"),
                selection: $settings.provider
            ) {
                ForEach(AIProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            switch settings.provider {
            case .anthropic:
                SecureField(
                    BrowserLocalization.string("ai_settings_api_key"),
                    text: $settings.anthropicAPIKey,
                    prompt: Text(verbatim: "sk-ant-…")
                )
                .textFieldStyle(.roundedBorder)
                Picker(
                    BrowserLocalization.string("ai_settings_model"),
                    selection: $settings.anthropicModel
                ) {
                    ForEach(AnthropicProvider.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            case .openAICompatible:
                SecureField(
                    BrowserLocalization.string("ai_settings_api_key"),
                    text: $settings.openAIAPIKey,
                    prompt: Text(verbatim: "sk-…")
                )
                .textFieldStyle(.roundedBorder)
                TextField(
                    BrowserLocalization.string("ai_settings_base_url"),
                    text: $settings.openAIBaseURLText
                )
                .textFieldStyle(.roundedBorder)
                TextField(
                    BrowserLocalization.string("ai_settings_model"),
                    text: $settings.openAIModel
                )
                .textFieldStyle(.roundedBorder)
            case .ollama:
                AIOllamaStatusView()
            }
        }
        .task {
            if settings.provider == .ollama { ollama.refresh() }
        }
        .onChange(of: settings.provider) { _, provider in
            if provider == .ollama { ollama.refresh() }
        }
    }
}

extension AIProviderKind {
    var displayName: String {
        switch self {
        case .anthropic: BrowserLocalization.string("ai_provider_anthropic")
        case .openAICompatible: BrowserLocalization.string("ai_provider_openai")
        case .ollama: BrowserLocalization.string("ai_provider_ollama")
        }
    }
}

/// Ollama detection, one-click install, and model provisioning.
struct AIOllamaStatusView: View {
    @Bindable private var settings = AIChatSettings.shared
    private var ollama: OllamaRuntime { OllamaRuntime.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow

            if case let .failed(message) = ollama.installPhase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pullError = ollama.pullError {
                Text(pullError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if ollama.status == .running {
                modelPicker
            }
        }
        .task { ollama.refresh() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch ollama.installPhase {
        case let .downloading(progress):
            progressRow(
                BrowserLocalization.string("ai_settings_ollama_downloading"),
                fraction: progress
            )
        case .extracting:
            progressRow(
                BrowserLocalization.string("ai_settings_ollama_extracting"),
                fraction: nil
            )
        case .launching:
            progressRow(
                BrowserLocalization.string("ai_settings_ollama_launching"),
                fraction: nil
            )
        case .waitingForServer:
            progressRow(
                BrowserLocalization.string("ai_settings_ollama_waiting"),
                fraction: nil
            )
        case .idle, .failed:
            installedStatusRow
        }
    }

    @ViewBuilder
    private var installedStatusRow: some View {
        switch ollama.status {
        case .running:
            if let pull = ollama.pullProgress {
                progressRow(
                    BrowserLocalization.string("ai_settings_ollama_pulling", pull.model),
                    fraction: pull.fraction
                )
            } else {
                Label(
                    BrowserLocalization.string("ai_settings_ollama_running"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(.green)
            }
        case .installedNotRunning:
            HStack(spacing: 8) {
                Text(BrowserLocalization.string("ai_settings_ollama_not_running"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(BrowserLocalization.string("ai_settings_ollama_launch")) {
                    ollama.launchInstalled()
                }
                .controlSize(.small)
            }
        case .notInstalled:
            HStack(spacing: 8) {
                Text(BrowserLocalization.string("ai_settings_ollama_not_installed"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(BrowserLocalization.string("ai_settings_ollama_install")) {
                    ollama.installAndLaunch()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        case .unknown, .checking:
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        if ollama.availableModels.isEmpty {
            HStack(spacing: 8) {
                Text(BrowserLocalization.string("ai_settings_ollama_no_models"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if ollama.pullProgress == nil {
                    Button(BrowserLocalization.string("ai_settings_ollama_pull_model")) {
                        ollama.pullModel(OllamaRuntime.recommendedModel)
                    }
                    .controlSize(.small)
                }
            }
        } else {
            Picker(
                BrowserLocalization.string("ai_settings_model"),
                selection: $settings.ollamaModel
            ) {
                ForEach(ollama.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .onAppear {
                if settings.ollamaModel.isEmpty {
                    settings.ollamaModel = ollama.availableModels[0]
                }
            }
        }
    }

    private func progressRow(_ title: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction {
                ProgressView(value: fraction)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
