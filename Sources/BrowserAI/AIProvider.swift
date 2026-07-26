import Foundation

/// A model backend that can stream a chat completion with tool support.
public protocol AIProvider: Sendable {
    func streamChat(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, any Error>
}

/// One parsed Server-Sent Event.
struct SSEEvent {
    var event: String?
    var data: String
}

/// Splits a byte stream into lines while **preserving empty lines**.
///
/// SSE terminates every event with a blank line, but Foundation's
/// `AsyncLineSequence` silently drops empty lines — using it here means no
/// event ever dispatches and the whole response reads as empty.
struct SSELineSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String

    let base: Base

    struct AsyncIterator: AsyncIteratorProtocol {
        private static var lineFeed: UInt8 { 0x0A }
        private static var carriageReturn: UInt8 { 0x0D }

        var base: Base.AsyncIterator
        var buffer: [UInt8] = []

        mutating func next() async throws -> String? {
            while let byte = try await base.next() {
                switch byte {
                case Self.lineFeed:
                    return takeLine()
                case Self.carriageReturn:
                    continue
                default:
                    buffer.append(byte)
                }
            }
            // A stream that ends without a trailing newline still has a line.
            return buffer.isEmpty ? nil : takeLine()
        }

        private mutating func takeLine() -> String {
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

extension AsyncSequence where Element == UInt8 {
    var sseLines: SSELineSequence<Self> { SSELineSequence(base: self) }
}

/// Incremental line-based SSE assembler shared by the streaming providers.
struct SSEParser {
    private var currentEvent: String?
    private var currentData: [String] = []

    mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty {
            defer {
                currentEvent = nil
                currentData = []
            }
            guard !currentData.isEmpty else { return nil }
            return SSEEvent(event: currentEvent, data: currentData.joined(separator: "\n"))
        }
        if line.hasPrefix(":") {
            return nil
        }
        if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst("event:".count))
                .trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            var value = String(line.dropFirst("data:".count))
            if value.hasPrefix(" ") { value.removeFirst() }
            currentData.append(value)
        }
        return nil
    }

    /// Emits a trailing event for servers that close the stream without the
    /// final blank line.
    mutating func flush() -> SSEEvent? {
        guard !currentData.isEmpty else { return nil }
        defer {
            currentEvent = nil
            currentData = []
        }
        return SSEEvent(event: currentEvent, data: currentData.joined(separator: "\n"))
    }
}

enum AIProviderHTTP {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Opens the SSE connection and validates the HTTP status, surfacing the
    /// provider's error body when the request is rejected.
    static func openStream(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> URLSession.AsyncBytes {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw AIProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.sseLines {
                body += body.isEmpty ? line : "\n" + line
                if body.count > 4000 { break }
            }
            throw AIProviderError.http(
                status: http.statusCode,
                message: Self.errorMessage(fromBody: body)
            )
        }
        return bytes
    }

    /// Providers wrap errors differently; try the common shapes before falling
    /// back to the raw body.
    private static func errorMessage(fromBody body: String) -> String {
        guard let data = body.data(using: .utf8),
              let value = try? JSONDecoder().decode(AIJSONValue.self, from: data)
        else { return String(body.prefix(300)) }
        if let message = value["error"]?["message"]?.stringValue {
            return message
        }
        if let message = value["error"]?.stringValue {
            return message
        }
        return String(body.prefix(300))
    }
}
