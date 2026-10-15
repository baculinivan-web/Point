import AppKit
import SwiftUI

/// Keeps the glyph size independent of its clickable area.
struct SidebarControlStyle: ButtonStyle {
    var showsHover = true

    func makeBody(configuration: Configuration) -> some View {
        ControlBody(configuration: configuration, showsHover: showsHover)
    }

    private struct ControlBody: View {
        let configuration: ButtonStyleConfiguration
        let showsHover: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isEnabled
                            ? (configuration.isPressed ? 0.14 : (isHovering && showsHover ? 0.08 : 0))
                            : 0))
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}

/// Dark transparent logos need a light backing in dark appearances.
struct FaviconArtwork: View {
    let image: NSImage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .background {
                if colorScheme == .dark, FaviconContrast.needsLightBacking(image) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(white: 0.9))
                        .padding(-2)
                }
            }
    }
}

@MainActor
private enum FaviconContrast {
    private static let cache: NSCache<NSImage, NSNumber> = {
        let cache = NSCache<NSImage, NSNumber>()
        cache.countLimit = 256
        return cache
    }()

    static func needsLightBacking(_ image: NSImage) -> Bool {
        if let cached = cache.object(forKey: image) { return cached.boolValue }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        var visible = 0
        var dark = 0
        for pixel in 0..<256 {
            let offset = pixel * 4
            let alpha = Double(data[offset + 3]) / 255
            guard alpha > 0.25 else { continue }
            visible += 1
            let luminance = (0.2126 * Double(data[offset])
                + 0.7152 * Double(data[offset + 1])
                + 0.0722 * Double(data[offset + 2])) / (255 * alpha)
            if luminance < 0.3 { dark += 1 }
        }
        let result = visible > 0 && Double(dark) / Double(visible) > 0.85
        cache.setObject(NSNumber(value: result), forKey: image)
        return result
    }
}
