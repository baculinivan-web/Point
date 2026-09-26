import AppKit
import BrowserAI
import BrowserCore
import SwiftUI

public enum BrowserSettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case assistant
    case agents
    case performance

    public var id: Self { self }

    var title: String {
        BrowserLocalization.string("settings_section_\(rawValue)")
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .assistant: "sparkles"
        case .agents: "network"
        case .performance: "memorychip"
        }
    }
}

public struct BrowserSettingsView: View {
    @Bindable private var model: BrowserWindowModel
    @AppStorage(BrowserMemoryLimitSettings.defaultsKey)
    private var memoryLimitFraction = BrowserMemoryLimitSettings.defaultFraction
    @Bindable private var aiSettings = AIChatSettings.shared
    @Bindable private var memories = AIMemoryStore.shared

    @State private var isDefaultBrowser = false
    @State private var isDefaultBrowserUpdateInProgress = false
    @State private var defaultBrowserError: String?
    @State private var isCheckingForUpdates = false
    @State private var updateCheckStatus: BrowserManualUpdate.CheckStatus?
    @State private var didCopyMCPCommand = false

    private let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory

    public init(model: BrowserWindowModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 158)

            Divider()

            VStack(spacing: 0) {
                settingsHeader
                Divider()
                selectedSettings
            }
        }
        .browserTintedGlass(
            cornerRadius: 22,
            tint: Color(nsColor: .windowBackgroundColor).opacity(0.08)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
        .onExitCommand { model.dismissSettings() }
        .onAppear(perform: refreshDefaultBrowserStatus)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshDefaultBrowserStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BrowserManualUpdate.checkFinished
            )
        ) { notification in
            guard let rawValue = notification.userInfo?[
                BrowserManualUpdate.statusUserInfoKey
            ] as? String,
            let status = BrowserManualUpdate.CheckStatus(rawValue: rawValue)
            else { return }
            updateCheckStatus = status
            isCheckingForUpdates = false
        }
        .onChange(of: memoryLimitFraction) { _, newValue in
            let normalized = BrowserMemoryLimitSettings.normalizedFraction(newValue)
            if normalized != newValue {
                memoryLimitFraction = normalized
            }
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(BrowserLocalization.string("settings_title"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            ForEach(BrowserSettingsSection.allCases) { section in
                Button {
                    model.presentedSettingsSection = section
                } label: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            selection == section
                                ? Color.accentColor.opacity(0.88)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .foregroundStyle(selection == section ? .white : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(12)
        .background(.primary.opacity(0.035))
    }

    private var settingsHeader: some View {
        HStack {
            Label(selection.title, systemImage: selection.symbol)
                .font(.headline)

            Spacer()

            Button {
                model.dismissSettings()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .help(BrowserLocalization.string("close"))
            .accessibilityLabel(BrowserLocalization.string("close"))
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general:
            generalSettings
        case .appearance:
            appearanceSettings
        case .assistant:
            assistantSettings
        case .agents:
            agentSettings
        case .performance:
            performanceSettings
        }
    }

    private var selection: BrowserSettingsSection {
        model.presentedSettingsSection ?? .general
    }

    private var generalSettings: some View {
        Form {
            Section(BrowserLocalization.string("default_browser")) {
                Text(BrowserLocalization.string("default_browser_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isDefaultBrowser {
                    Label(
                        BrowserLocalization.string("default_browser_current"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    Button(BrowserLocalization.string("make_default_browser")) {
                        makeDefaultBrowser()
                    }
                    .disabled(isDefaultBrowserUpdateInProgress)
                }

                if isDefaultBrowserUpdateInProgress {
                    ProgressView().controlSize(.small)
                }

                if let defaultBrowserError {
                    Text(defaultBrowserError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(BrowserLocalization.string("updates")) {
                Text(BrowserLocalization.string("updates_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(BrowserLocalization.string("check_for_updates")) {
                    isCheckingForUpdates = true
                    updateCheckStatus = nil
                    NotificationCenter.default.post(
                        name: BrowserManualUpdate.checkRequested,
                        object: nil
                    )
                }
                .disabled(isCheckingForUpdates)

                if isCheckingForUpdates {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(BrowserLocalization.string("checking_for_updates"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let updateCheckStatus {
                    Text(updateCheckStatusText(updateCheckStatus))
                        .font(.caption)
                        .foregroundStyle(
                            updateCheckStatus == .unavailable
                                || updateCheckStatus == .configurationMissing
                                ? .red : .secondary
                        )
                }
            }

            Section(BrowserLocalization.string("onboarding_section_title")) {
                Text(BrowserLocalization.string("onboarding_section_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(BrowserLocalization.string("onboarding_replay")) {
                    model.dismissSettings()
                    BrowserOnboarding.requestReplay()
                }
            }
        }
        .settingsFormStyle()
    }

    private var appearanceSettings: some View {
        Form {
            Section(BrowserLocalization.string("fullscreen_panels")) {
                Text(BrowserLocalization.string("fullscreen_panels_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                FullScreenPanelBackdropPicker()
            }
        }
        .settingsFormStyle()
    }

    private var assistantSettings: some View {
        Form {
            Section(BrowserLocalization.string("ai_settings_section")) {
                Text(BrowserLocalization.string("ai_settings_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker(
                    BrowserLocalization.string("ai_settings_provider"),
                    selection: $aiSettings.provider
                ) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                switch aiSettings.provider {
                case .anthropic:
                    SecureField(
                        BrowserLocalization.string("ai_settings_api_key"),
                        text: $aiSettings.anthropicAPIKey,
                        prompt: Text(verbatim: "sk-ant-…")
                    )
                    Picker(
                        BrowserLocalization.string("ai_settings_model"),
                        selection: $aiSettings.anthropicModel
                    ) {
                        ForEach(AnthropicProvider.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                case .openAICompatible:
                    SecureField(
                        BrowserLocalization.string("ai_settings_api_key"),
                        text: $aiSettings.openAIAPIKey,
                        prompt: Text(verbatim: "sk-…")
                    )
                    TextField(
                        BrowserLocalization.string("ai_settings_base_url"),
                        text: $aiSettings.openAIBaseURLText
                    )
                    TextField(
                        BrowserLocalization.string("ai_settings_model"),
                        text: $aiSettings.openAIModel
                    )
                case .ollama:
                    AIOllamaStatusView()
                }

                Toggle(
                    BrowserLocalization.string("ai_settings_share_page"),
                    isOn: $aiSettings.includesPageContext
                )
                .disabled(!model.hasExternalAgentOwnership)

                if !model.hasExternalAgentOwnership {
                    Label(
                        BrowserLocalization.string("agent_settings_owner_window"),
                        systemImage: "macwindow"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                LabeledContent(
                    BrowserLocalization.string("ai_settings_context_limit")
                ) {
                    TextField(
                        BrowserLocalization.string("ai_settings_context_limit"),
                        value: $aiSettings.contextLimitOverride,
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 90)
                }
                Text(BrowserLocalization.string("ai_settings_context_limit_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(BrowserLocalization.string("ai_settings_memory")) {
                Text(BrowserLocalization.string("ai_settings_memory_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent(
                    BrowserLocalization.string(
                        "ai_settings_memory_count",
                        memories.memories.count
                    )
                ) {
                    Button(
                        BrowserLocalization.string("ai_settings_memory_clear"),
                        role: .destructive
                    ) {
                        memories.forgetAll()
                    }
                    .disabled(memories.isEmpty)
                }
            }
        }
        .settingsFormStyle()
        .onAppear { aiSettings.loadAPIKeysIfNeeded() }
    }

    private var performanceSettings: some View {
        Form {
            Section(BrowserLocalization.string("memory_management")) {
                LabeledContent(BrowserLocalization.string("memory_limit")) {
                    Text(memoryLimitFraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }

                Slider(
                    value: $memoryLimitFraction,
                    in: BrowserMemoryLimitSettings.allowedRange,
                    step: 0.05
                ) {
                    Text(BrowserLocalization.string("memory_limit"))
                } minimumValueLabel: {
                    Text("25%").font(.caption)
                } maximumValueLabel: {
                    Text("90%").font(.caption)
                }

                Text(BrowserLocalization.string(
                    "memory_limit_detail",
                    formattedMemoryLimit
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsFormStyle()
    }

    private var agentSettings: some View {
        Form {
            Section {
                Toggle(
                    BrowserLocalization.string("agent_settings_enable_local"),
                    isOn: Binding(
                        get: { model.isExternalAgentAccessEnabled },
                        set: { enabled in
                            model.setExternalAgentAccessEnabled(enabled)
                            if enabled {
                                AgentConsentNotifier.prepare()
                            }
                        }
                    )
                )

                Text(BrowserLocalization.string("agent_settings_local_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isExternalAgentAccessEnabled {
                    Toggle(
                        BrowserLocalization.string("agent_settings_auto_approve"),
                        isOn: Binding(
                            get: { model.automaticallyAllowsExternalAgentControl },
                            set: { model.setAutomaticallyAllowsExternalAgentControl($0) }
                        )
                    )

                    Text(BrowserLocalization.string("agent_settings_auto_approve_detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent(BrowserLocalization.string("agent_settings_status")) {
                        Label(agentStatusText, systemImage: agentStatusSymbol)
                            .foregroundStyle(agentStatusColor)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(BrowserLocalization.string("agent_settings_command"))
                            .font(.caption.weight(.medium))
                        Text(model.pointMCPHelperPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.pointMCPHelperPath, forType: .string)
                            didCopyMCPCommand = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.5))
                                didCopyMCPCommand = false
                            }
                        } label: {
                            Label(
                                BrowserLocalization.string(
                                    didCopyMCPCommand ? "agent_settings_copied" : "agent_settings_copy"
                                ),
                                systemImage: didCopyMCPCommand ? "checkmark" : "doc.on.doc"
                            )
                        }
                    }
                }
            } header: {
                Text(BrowserLocalization.string("agent_settings_local"))
            }

            Section {
                Label(
                    BrowserLocalization.string("agent_settings_coming_soon"),
                    systemImage: "clock.badge"
                )
                .font(.callout.weight(.medium))

                Text(BrowserLocalization.string("agent_settings_remote_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(BrowserLocalization.string("agent_settings_remote"))
            }

            Section {
                Label(
                    BrowserLocalization.string("agent_settings_safety_detail"),
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(BrowserLocalization.string("agent_settings_safety"))
            }
        }
        .settingsFormStyle()
    }

    private var agentStatusText: String {
        switch model.externalAgentServerState {
        case .stopped: BrowserLocalization.string("agent_settings_status_stopped")
        case .listening: BrowserLocalization.string("agent_settings_status_ready")
        case .connected: BrowserLocalization.string("agent_settings_status_connected")
        case .failed: BrowserLocalization.string("agent_settings_status_failed")
        }
    }

    private var agentStatusSymbol: String {
        switch model.externalAgentServerState {
        case .connected: "checkmark.circle.fill"
        case .listening: "circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "circle"
        }
    }

    private var agentStatusColor: Color {
        switch model.externalAgentServerState {
        case .connected: .green
        case .listening: .blue
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private var formattedMemoryLimit: String {
        let bytes = UInt64(Double(physicalMemoryBytes) * memoryLimitFraction)
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }

    private func refreshDefaultBrowserStatus() {
        isDefaultBrowser = DefaultBrowserService.isDefaultBrowser()
    }

    private func updateCheckStatusText(
        _ status: BrowserManualUpdate.CheckStatus
    ) -> String {
        switch status {
        case .updateAvailable:
            BrowserLocalization.string("update_check_available")
        case .upToDate:
            BrowserLocalization.string("update_check_up_to_date")
        case .checkedRecently:
            BrowserLocalization.string("update_check_recently")
        case .unavailable:
            BrowserLocalization.string("update_check_failed")
        case .configurationMissing:
            BrowserLocalization.string("update_check_not_configured")
        case .checkInProgress:
            BrowserLocalization.string("checking_for_updates")
        }
    }

    private func makeDefaultBrowser() {
        defaultBrowserError = nil
        isDefaultBrowserUpdateInProgress = true
        DefaultBrowserService.makeDefaultBrowser { error in
            isDefaultBrowserUpdateInProgress = false
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

private extension View {
    func settingsFormStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}
