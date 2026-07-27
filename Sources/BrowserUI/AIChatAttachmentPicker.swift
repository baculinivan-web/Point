import AppKit
import BrowserAI
import BrowserCore
import PDFKit
import UniformTypeIdentifiers

/// Turns files the person picks into attachments the models can read.
///
/// Images are re-encoded and bounded so a screenshot does not blow up the
/// request; everything else is reduced to text on this side, which keeps
/// attachments working even on providers without document support.
enum AIChatAttachmentPicker {
    /// Anthropic's recommended long edge; also a sane cap for other providers.
    private static let maxImageEdge: CGFloat = 1568
    private static let maxTextCharacters = 40000

    static var supportedTypes: [UTType] {
        [.image, .pdf, .plainText, .sourceCode, .json, .xml, .commaSeparatedText, .rtf]
    }

    @MainActor
    static func present(allowsImages: Bool) -> [AIAttachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowsImages
            ? supportedTypes
            : supportedTypes.filter { $0 != .image }
        panel.message = allowsImages
            ? BrowserLocalization.string("ai_chat_attach_prompt")
            : BrowserLocalization.string("ai_chat_attach_prompt_text_only")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { attachment(for: $0, allowsImages: allowsImages) }
    }

    static func attachment(for url: URL, allowsImages: Bool) -> AIAttachment? {
        let type = UTType(filenameExtension: url.pathExtension)
        let name = url.lastPathComponent

        if allowsImages, type?.conforms(to: .image) == true {
            return imageAttachment(for: url, name: name)
        }
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { return nil }
            let text = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
            return textAttachment(name: name, text: text)
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return textAttachment(name: name, text: raw)
    }

    private static func textAttachment(name: String, text: String) -> AIAttachment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AIAttachment(
            kind: .text,
            name: name,
            text: String(trimmed.prefix(maxTextCharacters))
        )
    }

    private static func imageAttachment(for url: URL, name: String) -> AIAttachment? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        guard let data = jpegData(from: image) else { return nil }
        return AIAttachment(
            kind: .image,
            name: name,
            mediaType: "image/jpeg",
            data: data
        )
    }

    /// Downscales to `maxImageEdge` and re-encodes as JPEG so every provider
    /// gets a format it accepts at a predictable size.
    private static func jpegData(from image: NSImage) -> Data? {
        guard let source = image.representations.first else { return nil }
        let pixelSize = CGSize(
            width: CGFloat(source.pixelsWide),
            height: CGFloat(source.pixelsHigh)
        )
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        let scale = min(1, maxImageEdge / max(pixelSize.width, pixelSize.height))
        let targetSize = CGSize(
            width: max(1, (pixelSize.width * scale).rounded()),
            height: max(1, (pixelSize.height * scale).rounded())
        )

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        )
    }
}
