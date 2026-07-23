import BrowserCore
import SwiftUI

public struct BrowserSettingsView: View {
    @AppStorage(BrowserMemoryLimitSettings.defaultsKey)
    private var memoryLimitFraction = BrowserMemoryLimitSettings.defaultFraction

    private let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory

    public init() {}

    public var body: some View {
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
        .frame(width: 480, height: 220)
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
}
