import AppKit
import BrowserCore
import SwiftUI

enum FullScreenPanelBackdrop: String, CaseIterable, Identifiable {
    static let defaultsKey = "FullScreenPanelBackdrop"
    static let customStartColorKey = "FullScreenPanelCustomGradientStart"
    static let customEndColorKey = "FullScreenPanelCustomGradientEnd"

    case aurora
    case sunset
    case ocean
    case custom

    var id: Self { self }

    var title: String {
        BrowserLocalization.string("fullscreen_panel_backdrop_\(rawValue)")
    }

    @ViewBuilder
    func gradient(startColor: Color, endColor: Color) -> some View {
        switch self {
        case .aurora:
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.10, blue: 0.32),
                    Color(red: 0.18, green: 0.60, blue: 0.58),
                    Color(red: 0.56, green: 0.34, blue: 0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .sunset:
            LinearGradient(
                colors: [
                    Color(red: 0.31, green: 0.12, blue: 0.34),
                    Color(red: 0.90, green: 0.38, blue: 0.28),
                    Color(red: 0.98, green: 0.71, blue: 0.38)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        case .ocean:
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.18, blue: 0.32),
                    Color(red: 0.05, green: 0.48, blue: 0.62),
                    Color(red: 0.42, green: 0.82, blue: 0.77)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .custom:
            LinearGradient(
                colors: [startColor, endColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// Supplies color for full-screen glass, where there is no desktop behind the
/// window for the system material to sample.
struct FullScreenPanelBackdropView: View {
    @AppStorage(FullScreenPanelBackdrop.defaultsKey)
    private var backdropRawValue = FullScreenPanelBackdrop.aurora.rawValue
    @AppStorage(FullScreenPanelBackdrop.customStartColorKey)
    private var customStartHex = "#5C3DCC"
    @AppStorage(FullScreenPanelBackdrop.customEndColorKey)
    private var customEndHex = "#25B8B0"

    var body: some View {
        backdrop.gradient(
            startColor: Color(panelGradientHex: customStartHex),
            endColor: Color(panelGradientHex: customEndHex)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var backdrop: FullScreenPanelBackdrop {
        FullScreenPanelBackdrop(rawValue: backdropRawValue) ?? .aurora
    }
}

struct FullScreenPanelBackdropPicker: View {
    @AppStorage(FullScreenPanelBackdrop.defaultsKey)
    private var backdropRawValue = FullScreenPanelBackdrop.aurora.rawValue
    @AppStorage(FullScreenPanelBackdrop.customStartColorKey)
    private var customStartHex = "#5C3DCC"
    @AppStorage(FullScreenPanelBackdrop.customEndColorKey)
    private var customEndHex = "#25B8B0"

    var body: some View {
        Picker(
            BrowserLocalization.string("fullscreen_panel_backdrop_picker"),
            selection: backdropBinding
        ) {
            ForEach(FullScreenPanelBackdrop.allCases) { option in
                Text(option.title).tag(option)
            }
        }

        if backdrop == .custom {
            ColorPicker(
                BrowserLocalization.string("fullscreen_panel_custom_start"),
                selection: customStartColor,
                supportsOpacity: false
            )
            ColorPicker(
                BrowserLocalization.string("fullscreen_panel_custom_end"),
                selection: customEndColor,
                supportsOpacity: false
            )
        }
    }

    private var backdrop: FullScreenPanelBackdrop {
        FullScreenPanelBackdrop(rawValue: backdropRawValue) ?? .aurora
    }

    private var backdropBinding: Binding<FullScreenPanelBackdrop> {
        Binding(
            get: { backdrop },
            set: { backdropRawValue = $0.rawValue }
        )
    }

    private var customStartColor: Binding<Color> {
        Binding(
            get: { Color(panelGradientHex: customStartHex) },
            set: { customStartHex = $0.panelGradientHex }
        )
    }

    private var customEndColor: Binding<Color> {
        Binding(
            get: { Color(panelGradientHex: customEndHex) },
            set: { customEndHex = $0.panelGradientHex }
        )
    }
}

private extension Color {
    init(panelGradientHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            self = .accentColor
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var panelGradientHex: String {
        let rgb = NSColor(self).usingColorSpace(.deviceRGB) ?? .controlAccentColor
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
