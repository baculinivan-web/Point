import BrowserAI
import BrowserCore
import SwiftUI

public struct BrowserSettingsView: View {
    @AppStorage(BrowserMemoryLimitSettings.defaultsKey)
    private var memoryLimitFraction = BrowserMemoryLimitSettings.defaultFraction
    @Bindable private var aiSettings = AIChatSettings.shared
    @Bindable private var memories = AIMemoryStore.shared

    @State private var isDefaultBrowser = false
    @State private var isDefaultBrowserUpdateInProgress = false
    @State private var defaultBrowserError: String?
    @State private var isCheckingForUpdates = false
    @State private var updateCheckStatus: BrowserManualUpdate.CheckStatus?

    private let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory

    public init() {}

    public var body: some View {
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
                    ProgressView()
                        .controlSize(.small)
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
                        ProgressView()
                            .controlSize(.small)
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
                    BrowserOnboarding.requestReplay()
                }
            }

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

                LabeledContent(
                    BrowserLocalization.string("ai_settings_context_limit")
                ) {
                    TextField(
                        BrowserLocalization.string("ai_settings_context_limit"),
                        value: $aiSettings.contextLimitOverride,
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 100)
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
                    Text("25%")
                        .font(.caption)
                } maximumValueLabel: {
                    Text("90%")
                        .font(.caption)
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
        .formStyle(.grouped)
        .frame(width: 480, height: 670)
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
            else {
                return
            }
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
