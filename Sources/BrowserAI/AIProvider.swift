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
            for try await line in bytes.lines {
                body += line
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
