import AppKit
import BrowserAI
import BrowserCore
import SwiftUI

/// The assistant panel docked to the trailing edge of a browser window.
struct AIChatPanelView: View {
    let model: BrowserWindowModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            AIChatHeaderView(
                title: BrowserLocalization.string("ai_chat_title"),
                subtitle: AIChatSettings.shared.isConfigured
                    ? AIChatSettings.shared.activeModelName
                    : nil,
                onClear: model.aiChat.isEmpty ? nil : { model.aiChat.clear() },
                onDetach: { model.detachAIChat() },
                onClose: { model.dismissAIChat() }
            )
            Divider()
            AIChatConversationView(session: model.aiChat)
        }
        .frame(width: AIChatLayout.panelWidth)
        .background { panelBackground }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.separator.opacity(0.6))
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrowserLocalization.string("ai_chat_title"))
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

enum AIChatLayout {
    static let panelWidth: CGFloat = 360
}

// MARK: - Detached window

/// The assistant conversation living in its own window after a detach.
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
                        title: BrowserLocalization.string("ai_chat_window_title"),
                        subtitle: AIChatSettings.shared.isConfigured
                            ? AIChatSettings.shared.activeModelName
                            : nil,
                        onClear: session.isEmpty ? nil : { session.clear() },
                        onReattach: {
                            session.isDetached = false
                            session.onReattachRequest?()
                        }
                    )
                    Divider()
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
        .frame(minWidth: 380, idealWidth: 440, minHeight: 460, idealHeight: 640)
    }
}

// MARK: - Header

private struct AIChatHeaderView: View {
    let title: String
    let subtitle: String?
    var onClear: (() -> Void)?
    var onDetach: (() -> Void)?
    var onReattach: (() -> Void)?
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let onClear {
                headerButton(
                    symbol: "square.and.pencil",
                    help: BrowserLocalization.string("ai_chat_clear"),
                    action: onClear
                )
            }
            if let onDetach {
                headerButton(
                    symbol: "rectangle.portrait.and.arrow.right",
                    help: BrowserLocalization.string("ai_chat_detach"),
                    action: onDetach
                )
            }
            if let onReattach {
                headerButton(
                    symbol: "rectangle.trailinghalf.inset.filled.arrow.trailing",
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
        .frame(height: 46)
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
    @FocusState private var isInputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if !settings.isConfigured {
                AIChatSetupView()
            } else if session.isEmpty {
                emptyState
            } else {
                transcript
            }

            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
            }

            composer
        }
        .task {
            await Task.yield()
            isInputFocused = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.85))
            Text(BrowserLocalization.string("ai_chat_empty_title"))
                .font(.headline)
            Text(BrowserLocalization.string("ai_chat_empty_message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
                            .id("typing")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: session.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: session.messages.last?.text) {
                scrollToBottom(proxy)
            }
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    BrowserLocalization.string("ai_chat_input_placeholder"),
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isInputFocused)
                .onSubmit(sendDraft)

                if session.isStreaming {
                    Button(action: session.cancelStreaming) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 21))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help(BrowserLocalization.string("ai_chat_stop"))
                    .accessibilityLabel(BrowserLocalization.string("ai_chat_stop"))
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 21))
                            .foregroundStyle(
                                canSend ? Color.accentColor : Color.secondary.opacity(0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(BrowserLocalization.string("ai_chat_send"))
                    .accessibilityLabel(BrowserLocalization.string("ai_chat_send"))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))

            Toggle(isOn: $settings.includesPageContext) {
                Label(
                    BrowserLocalization.string("ai_chat_share_page"),
                    systemImage: "doc.text.magnifyingglass"
                )
                .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var canSend: Bool {
        settings.isConfigured
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard canSend, !session.isStreaming else { return }
        let text = draft
        draft = ""
        session.send(text, includePageContext: settings.includesPageContext)
    }
}

// MARK: - Messages

private struct AIChatMessageView: View {
    let message: AIChatMessage

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if let context = message.pageContext {
                    Label(
                        BrowserLocalization.string(
                            "ai_chat_context_badge",
                            context.url.host ?? context.title
                        ),
                        systemImage: "doc.text"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        Color.accentColor.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 32)
        case .assistant:
            VStack(alignment: .leading, spacing: 7) {
                ForEach(message.toolActivities) { activity in
                    AIChatToolActivityView(activity: activity)
                }
                if !message.text.isEmpty {
                    Text(Self.render(message.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func render(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
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
        .background(.quaternary.opacity(0.55), in: Capsule())
        .help(helpText)
    }

    private var symbol: String {
        switch activity.name {
        case "web_search": "magnifyingglass"
        case "open_tab": "plus.rectangle.on.rectangle"
        case "read_page": "doc.text.magnifyingglass"
        default: "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch activity.name {
        case "web_search": BrowserLocalization.string("ai_tool_web_search")
        case "open_tab": BrowserLocalization.string("ai_tool_open_tab")
        case "read_page": BrowserLocalization.string("ai_tool_read_page")
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
        .task {
            phase = true
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Setup

/// Shown inside the panel until a provider is configured. Mirrors the
/// Settings section so people can finish setup without leaving the chat.
struct AIChatSetupView: View {
    @Bindable private var settings = AIChatSettings.shared
    private let ollama = OllamaRuntime.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        BrowserLocalization.string("ai_setup_title"),
                        systemImage: "sparkles"
                    )
                    .font(.headline)
                    Text(BrowserLocalization.string("ai_setup_message"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                SettingsLink {
                    Text(BrowserLocalization.string("ai_setup_open_settings"))
                }
                .controlSize(.small)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if settings.provider == .ollama {
                ollama.refresh()
            }
        }
        .onChange(of: settings.provider) { _, provider in
            if provider == .ollama {
                ollama.refresh()
            }
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
/// Shared by the panel setup card and the Settings pane.
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
