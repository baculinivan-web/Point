import BrowserCore
import SwiftUI

public struct BrowserSettingsView: View {
    @AppStorage(BrowserMemoryLimitSettings.defaultsKey)
    private var memoryLimitFraction = BrowserMemoryLimitSettings.defaultFraction

    @State private var isDefaultBrowser = false
    @State private var isDefaultBrowserUpdateInProgress = false
    @State private var defaultBrowserError: String?

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
        .frame(width: 480, height: 340)
        .onAppear(perform: refreshDefaultBrowserStatus)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshDefaultBrowserStatus()
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
