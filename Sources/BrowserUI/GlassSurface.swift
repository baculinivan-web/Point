import SwiftUI

struct BrowserGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }
        } else if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Tinted Liquid Glass, used where the surface should read as a pane of glass
/// over the desktop rather than an opaque panel.
struct BrowserTintedGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let tint: Color?
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(shape)
                .overlay { shape.stroke(.separator, lineWidth: 1) }
        } else if #available(macOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(shape)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @available(macOS 26, *)
    private var glass: Glass {
        let base = isInteractive ? Glass.regular.interactive() : Glass.regular
        return tint.map { base.tint($0) } ?? base
    }
}

extension View {
    func browserGlassSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(BrowserGlassSurface(cornerRadius: cornerRadius))
    }

    func browserTintedGlass(
        cornerRadius: CGFloat = 0,
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            BrowserTintedGlass(
                cornerRadius: cornerRadius,
                tint: tint,
                isInteractive: isInteractive
            )
        )
    }
}
