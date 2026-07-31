import Foundation
import Testing
@testable import BrowserAI

/// Emits a fixed byte payload, standing in for `URLSession.AsyncBytes`.
private struct ByteFeed: AsyncSequence {
    typealias Element = UInt8
    let bytes: [UInt8]

    struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: [UInt8]
        var index = 0

        mutating func next() async -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(bytes: bytes) }
}

private func feed(_ text: String) -> ByteFeed {
    ByteFeed(bytes: Array(text.utf8))
}

@Suite("SSE line splitting")
struct SSELineSequenceTests {
    /// Foundation's `AsyncLineSequence` drops blank lines, which would hide
    /// every SSE event boundary — the reason this type exists.
    @Test func preservesBlankLinesThatTerminateEvents() async throws {
        var lines: [String] = []
        for try await line in feed("data: a\n\ndata: b\n\n").sseLines {
            lines.append(line)
        }
        #expect(lines == ["data: a", "", "data: b", ""])
    }

    @Test func handlesCarriageReturnsAndMissingTrailingNewline() async throws {
        var lines: [String] = []
        for try await line in feed("data: a\r\n\r\ndata: b").sseLines {
            lines.append(line)
        }
        #expect(lines == ["data: a", "", "data: b"])
    }

    @Test func decodesMultiByteCharactersSplitAcrossReads() async throws {
        var lines: [String] = []
        for try await line in feed("data: Привет 👋\n\n").sseLines {
            lines.append(line)
        }
        #expect(lines.first == "data: Привет 👋")
    }
}

/// End-to-end over the byte stream: the layer that was previously untested and
/// where a dropped blank line silently produced an empty response.
@Suite("SSE stream to events")
struct SSEEndToEndTests {
    private func openAIEvents(from payload: String) async throws -> [AIStreamEvent] {
        var parser = SSEParser()
        var assembler = OpenAIStreamAssembler()
        var events: [AIStreamEvent] = []
        for try await line in feed(payload).sseLines {
            guard let event = parser.consume(line: line) else { continue }
            if event.data == "[DONE]" { break }
            events.append(contentsOf: assembler.handle(dataPayload: event.data))
        }
        events.append(contentsOf: assembler.finish())
        return events
    }

    private func text(of events: [AIStreamEvent]) -> String {
        events.reduce(into: "") { result, event in
            if case let .textDelta(delta) = event { result += delta }
        }
    }

    @Test func openAIStreamProducesText() async throws {
        let payload = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":", world"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let events = try await openAIEvents(from: payload)
        #expect(text(of: events) == "Hello, world")
    }

    /// Some gateways interleave keep-alive comments; they must not break parsing.
    @Test func openAIStreamToleratesKeepAliveComments() async throws {
        let payload = """
        : OPENROUTER PROCESSING

        data: {"choices":[{"delta":{"content":"Hi"}}]}

        : OPENROUTER PROCESSING

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let events = try await openAIEvents(from: payload)
        #expect(text(of: events) == "Hi")
    }

    /// A server that closes without the final blank line still delivers its
    /// last event via the parser flush.
    @Test func openAIStreamWithoutTrailingBlankLine() async throws {
        var parser = SSEParser()
        var assembler = OpenAIStreamAssembler()
        var events: [AIStreamEvent] = []
        let payload = """
        data: {"choices":[{"delta":{"content":"Tail"}}]}
        """
        for try await line in feed(payload).sseLines {
            if let event = parser.consume(line: line) {
                events.append(contentsOf: assembler.handle(dataPayload: event.data))
            }
        }
        if let trailing = parser.flush() {
            events.append(contentsOf: assembler.handle(dataPayload: trailing.data))
        }
        events.append(contentsOf: assembler.finish())
        #expect(text(of: events) == "Tail")
    }

    @Test func anthropicStreamProducesText() async throws {
        let payload = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"there"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        var parser = SSEParser()
        var assembler = AnthropicStreamAssembler()
        var events: [AIStreamEvent] = []
        for try await line in feed(payload).sseLines {
            guard let event = parser.consume(line: line) else { continue }
            events.append(contentsOf: assembler.handle(event))
        }
        events.append(contentsOf: assembler.finish())

        #expect(text(of: events) == "Hi there")
        guard case let .finished(reason)? = events.last else {
            Issue.record("expected a finish event")
            return
        }
        #expect(reason == .endTurn)
    }
}
