@testable import BrowserUI
import Darwin
import Foundation
import Testing

@Suite("MCP socket ownership")
struct PointMCPSocketListenerTests {
    @Test func secondOwnerCannotReplaceOrRemoveLiveEndpoint() throws {
        try withSocket { url in
            let owner = try PointMCPSocketListener(socketURL: url, maximumClients: 4)
            #expect(throws: POSIXError.self) {
                _ = try PointMCPSocketListener(socketURL: url, maximumClients: 4)
            }
            try assertConnects(to: url)
            withExtendedLifetime(owner) {}
        }
    }

    @Test func stoppedOwnerAllowsAnotherListener() throws {
        try withSocket { url in
            var owner: PointMCPSocketListener? = try PointMCPSocketListener(socketURL: url, maximumClients: 4)
            #expect(owner != nil)
            owner = nil
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let successor = try PointMCPSocketListener(socketURL: url, maximumClients: 4)
            try assertConnects(to: url)
            withExtendedLifetime(successor) {}
        }
    }

    @Test func refusedStaleEndpointIsRecovered() throws {
        try withSocket { url in
            let stale = try bindLegacySocket(at: url, listening: false)
            Darwin.close(stale)
            let owner = try PointMCPSocketListener(socketURL: url, maximumClients: 4)
            try assertConnects(to: url)
            withExtendedLifetime(owner) {}
        }
    }

    @Test func legacyListenerWithoutLockIsPreserved() throws {
        try withSocket { url in
            let legacy = try bindLegacySocket(at: url, listening: true)
            defer { Darwin.close(legacy) }
            #expect(throws: POSIXError.self) {
                _ = try PointMCPSocketListener(socketURL: url, maximumClients: 4)
            }
            try assertConnects(to: url)
        }
    }

    @Test func oldOwnerDoesNotUnlinkReplacementEndpoint() throws {
        try withSocket { url in
            var owner: PointMCPSocketListener? = try PointMCPSocketListener(socketURL: url, maximumClients: 4)
            #expect(owner != nil)
            #expect(Darwin.unlink(url.path) == 0)
            let replacement = try bindLegacySocket(at: url, listening: true)
            defer { Darwin.close(replacement) }
            owner = nil
            try assertConnects(to: url)
        }
    }

    @Test func unrelatedFileAtEndpointIsPreserved() throws {
        try withSocket { url in
            try Data("keep".utf8).write(to: url)
            #expect(throws: POSIXError.self) {
                _ = try PointMCPSocketListener(socketURL: url, maximumClients: 4)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "keep")
        }
    }

    private func withSocket(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pmcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appending(path: "agent.sock"))
    }

    private func withAddress<T>(_ url: URL, _ body: (UnsafePointer<sockaddr>) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8CString)
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                _ = memcpy(destination, source.baseAddress!, source.count)
            }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
        }
    }

    private func bindLegacySocket(at url: URL, listening: Bool) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        do {
            let result = try withAddress(url) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            try #require(result == 0)
            if listening { try #require(Darwin.listen(fd, 4) == 0) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func assertConnects(to url: URL) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }
        let result = try withAddress(url) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        #expect(result == 0)
    }
}
