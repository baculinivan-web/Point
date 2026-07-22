import BrowserCore
import Foundation
import Testing

@Suite("Download filename sanitizer")
struct DownloadFilenameSanitizerTests {
    @Test("Only in-progress download states are active")
    func activeStates() {
        #expect(DownloadState.awaitingDestination.isActive)
        #expect(DownloadState.downloading.isActive)
        #expect(!DownloadState.finished.isActive)
        #expect(!DownloadState.cancelled.isActive)
        #expect(!DownloadState.failed("network").isActive)
    }

    @Test("Path traversal is reduced to a safe leaf name")
    func traversal() {
        #expect(DownloadFilenameSanitizer.sanitize("../../report.pdf") == "report.pdf")
        #expect(DownloadFilenameSanitizer.sanitize("..\\secret.txt") == "_secret.txt")
    }

    @Test("Separators and control characters are replaced")
    func forbiddenCharacters() {
        #expect(DownloadFilenameSanitizer.sanitize("invoice:Q3\u{0000}.pdf") == "invoice_Q3_.pdf")
    }

    @Test("Empty and dot-only names use the fallback")
    func fallback() {
        #expect(DownloadFilenameSanitizer.sanitize("..") == "download")
        #expect(DownloadFilenameSanitizer.sanitize("   ") == "download")
        #expect(DownloadFilenameSanitizer.sanitize(".", fallback: "file") == "file")
    }

    @Test("Names have a bounded filesystem-friendly length")
    func boundedLength() {
        let result = DownloadFilenameSanitizer.sanitize(String(repeating: "a", count: 300))
        #expect(result.count == 180)
    }

    @Test("Destination resolver preserves files and adds a numeric suffix")
    func collisionResolution() {
        let directory = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let occupied = Set([
            "/Downloads/report.pdf",
            "/Downloads/report 2.pdf"
        ])
        let destination = DownloadDestinationResolver.availableURL(
            in: directory,
            suggestedFilename: "report.pdf",
            fileExists: { occupied.contains($0.path) }
        )

        #expect(destination.path == "/Downloads/report 3.pdf")
    }

    @Test("Destination resolver handles extensionless names")
    func extensionlessCollision() {
        let directory = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let destination = DownloadDestinationResolver.availableURL(
            in: directory,
            suggestedFilename: "archive",
            fileExists: { $0.lastPathComponent == "archive" }
        )

        #expect(destination.lastPathComponent == "archive 2")
    }
}
