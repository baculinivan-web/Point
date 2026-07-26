import Foundation
import Testing
@testable import BrowserAI

@Suite("SSE parsing")
struct SSEParserTests {
    @Test func assemblesEventAcrossLines() {
        var parser = SSEParser()
        #expect(parser.consume(line: "event: message_start") == nil)
        #expect(parser.consume(line: "data: {\"a\":1}") == nil)
        let event = parser.consume(line: "")
        #expect(event?.event == "message_start")
        #expect(event?.data == "{\"a\":1}")
    }

    @Test func ignoresCommentsAndJoinsMultilineData() {
        var parser = SSEParser()
        #expect(parser.consume(line: ": keep-alive") == nil)
        #expect(parser.consume(line: "data: one") == nil)
        #expect(parser.consume(line: "data: two") == nil)
        let event = parser.consume(line: "")
        #expect(event?.data == "one\ntwo")
        #expect(parser.consume(line: "") == nil)
    }
}

@Suite("Anthropic stream assembly")
struct AnthropicAssemblerTests {
    private func event(_ json: String) -> SSEEvent {
        SSEEvent(event: nil, data: json)
    }

    @Test func emitsTextDeltas() {
        var assembler = AnthropicStreamAssembler()
        let events = assembler.handle(event(
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        ))
        guard case let .textDelta(text)? = events.first else {
            Issue.record("expected text delta")
            return
        }
        #expect(text == "Hi")
    }

    @Test func assemblesToolUseFromJSONFragments() {
        var assembler = AnthropicStreamAssembler()
        _ = assembler.handle(event(
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"web_search"}}"#
        ))
        _ = assembler.handle(event(
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#
        ))
        _ = assembler.handle(event(
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"swift\"}"}}"#
        ))
        let events = assembler.handle(event(
            #"{"type":"content_block_stop","index":1}"#
        ))
        guard case let .toolCall(call)? = events.first else {
            Issue.record("expected tool call")
            return
        }
        #expect(call.id == "toolu_1")
        #expect(call.name == "web_search")
        #expect(call.arguments["query"]?.stringValue == "swift")
    }

    @Test func reportsStopReason() {
        var assembler = AnthropicStreamAssembler()
        _ = assembler.handle(event(
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#
        ))
        let events = assembler.handle(event(#"{"type":"message_stop"}"#))
        guard case let .finished(reason)? = events.first else {
            Issue.record("expected finish")
            return
        }
        #expect(reason == .toolUse)
        #expect(assembler.finish() == nil)
    }
}

@Suite("OpenAI-compatible stream assembly")
struct OpenAIAssemblerTests {
    @Test func emitsTextAndFinish() {
        var assembler = OpenAIStreamAssembler()
        let first = assembler.handle(dataPayload:
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#
        )
        guard case let .textDelta(text)? = first.first else {
            Issue.record("expected text delta")
            return
        }
        #expect(text == "Hel")

        let final = assembler.handle(dataPayload:
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        )
        guard case let .finished(reason)? = final.last else {
            Issue.record("expected finish")
            return
        }
        #expect(reason == .endTurn)
    }

    @Test func assemblesFragmentedToolCalls() {
        var assembler = OpenAIStreamAssembler()
        _ = assembler.handle(dataPayload:
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"open_tab","arguments":"{\"url\":"}}]}}]}"#
        )
        _ = assembler.handle(dataPayload:
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"https://example.com\"}"}}]}}]}"#
        )
        let events = assembler.handle(dataPayload:
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
        )
        let toolCalls = events.compactMap { event -> AIToolCall? in
            if case let .toolCall(call) = event { return call }
            return nil
        }
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "call_1")
        #expect(toolCalls.first?.name == "open_tab")
        #expect(toolCalls.first?.arguments["url"]?.stringValue == "https://example.com")
        guard case .finished(.toolUse)? = events.last else {
            Issue.record("expected tool_use finish")
            return
        }
    }
}

@Suite("Web search parsing")
struct AIWebSearchParseTests {
    @Test func extractsResultsAndUnwrapsRedirects() {
        let html = """
        <div class="result">
          <a rel="nofollow" class="result__a" \
        href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&amp;rut=abc">\
        Example <b>Title</b></a>
          <a class="result__snippet" href="#">Some &amp; snippet text</a>
        </div>
        """
        let results = AIWebSearch.parse(html: html, limit: 5)
        #expect(results.count == 1)
        #expect(results.first?.title == "Example Title")
        #expect(results.first?.url.absoluteString == "https://example.com/page")
        #expect(results.first?.snippet == "Some & snippet text")
    }

    @Test func respectsLimit() {
        let entry = """
        <a class="result__a" href="https://example.com/a">A</a>
        <a class="result__snippet" href="#">s</a>
        """
        let html = Array(repeating: entry, count: 10).joined()
        #expect(AIWebSearch.parse(html: html, limit: 3).count == 3)
    }
}

@Suite("Request bodies")
struct RequestBodyTests {
    private let request = AIChatRequest(
        model: "claude-opus-5",
        system: "sys",
        messages: [
            .user("hello"),
            .assistant(text: "hi", toolCalls: [
                AIToolCall(id: "t1", name: "web_search", arguments: .object([
                    "query": .string("swift")
                ]))
            ]),
            .toolResults([AIToolResult(callID: "t1", content: "result")])
        ],
        tools: [
            AIToolSpec(
                name: "web_search",
                description: "d",
                parameters: .object(["type": .string("object")])
            )
        ],
        maxTokens: 100
    )

    @Test func anthropicBodyShape() throws {
        let body = AnthropicProvider.requestBody(for: request)
        #expect(body["model"] as? String == "claude-opus-5")
        #expect(body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "user")
        let toolResultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(toolResultBlocks.first?["type"] as? String == "tool_result")
        #expect(toolResultBlocks.first?["tool_use_id"] as? String == "t1")
    }

    @Test func openAIBodyShape() throws {
        let body = OpenAICompatibleProvider.requestBody(for: request)
        let messages = try #require(body["messages"] as? [[String: Any]])
        // system + user + assistant + one tool result
        #expect(messages.count == 4)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[3]["role"] as? String == "tool")
        #expect(messages[3]["tool_call_id"] as? String == "t1")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
    }
}
