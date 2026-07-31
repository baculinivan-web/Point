import Foundation
import Testing

@testable import BrowserAI

private func request(
    system: String = String(repeating: "stable instructions. ", count: 200),
    systemContext: String = "",
    messages: [AIConversationMessage],
    tools: [AIToolSpec] = []
) -> AIChatRequest {
    AIChatRequest(
        model: "claude-opus-5",
        system: system,
        systemContext: systemContext,
        messages: messages,
        tools: tools,
        maxTokens: 1000
    )
}

private let sampleTool = AIToolSpec(
    name: "web_search",
    description: "Search the web.",
    parameters: .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])])
    ])
)

private func cacheControl(of block: [String: Any]) -> [String: Any]? {
    block["cache_control"] as? [String: Any]
}

private func blocks(of message: [String: Any]) -> [[String: Any]]? {
    message["content"] as? [[String: Any]]
}

@Suite("Anthropic prompt caching")
struct AnthropicPromptCachingTests {
    @Test("The stable system prompt carries the long-lived breakpoint")
    func systemBreakpoint() throws {
        let body = AnthropicProvider.requestBody(
            for: request(messages: [.user(text: "hi")], tools: [sampleTool])
        )
        let system = try #require(body["system"] as? [[String: Any]])
        let control = try #require(cacheControl(of: system[0]))
        #expect(control["type"] as? String == "ephemeral")
        // Identical on every request in every conversation, so it earns the
        // hour-long TTL rather than the five-minute default.
        #expect(control["ttl"] as? String == "1h")
    }

    @Test("Volatile system context sits after the breakpoint, uncached")
    func volatileContextIsNotCached() throws {
        let body = AnthropicProvider.requestBody(
            for: request(
                systemContext: "Things you remember: the person prefers Swift.",
                messages: [.user(text: "hi")]
            )
        )
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect(cacheControl(of: system[0]) != nil)
        // A changed memory must not invalidate the prompt in front of it.
        #expect(cacheControl(of: system[1]) == nil)
    }

    @Test("With no system prompt the breakpoint falls back to the last tool")
    func toolBreakpointFallback() throws {
        let body = AnthropicProvider.requestBody(
            for: request(system: "", messages: [.user(text: "hi")], tools: [sampleTool])
        )
        #expect(body["system"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(cacheControl(of: tools[0])?["ttl"] as? String == "1h")
    }

    @Test("The newest turn always carries a conversation breakpoint")
    func newestTurnIsMarked() throws {
        let body = AnthropicProvider.requestBody(
            for: request(messages: [
                .user(text: "first"),
                .assistant(text: "reply", toolCalls: []),
                .user(text: "second")
            ])
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let last = try #require(blocks(of: messages[2]))
        #expect(cacheControl(of: last[0]) != nil)
        // Conversation breakpoints use the default 5-minute TTL.
        #expect(cacheControl(of: last[0])?["ttl"] == nil)
    }

    @Test("Plain-string content is promoted to blocks so it can be marked")
    func stringContentIsPromoted() throws {
        let body = AnthropicProvider.requestBody(
            for: request(messages: [.user(text: "only turn")])
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let marked = try #require(blocks(of: messages[0]))
        #expect(marked[0]["type"] as? String == "text")
        #expect(marked[0]["text"] as? String == "only turn")
        #expect(cacheControl(of: marked[0]) != nil)
    }

    @Test("A long turn gets a second anchor inside the lookback window")
    func secondAnchorForLongTurns() {
        // One agent round can append more than twenty blocks; without an
        // earlier anchor the next request's breakpoint finds nothing.
        let manyResults = (0..<20).map { AIToolResult(callID: "t\($0)", content: "r") }
        let indices = AnthropicProvider.cacheBreakpointIndices(for: [
            .user(text: "go"),
            .assistant(text: "", toolCalls: []),
            .toolResults(manyResults)
        ])
        #expect(indices.count == 2)
        #expect(indices.contains(2))
    }

    @Test("Short conversations need only the one breakpoint")
    func shortConversationHasOneBreakpoint() {
        let indices = AnthropicProvider.cacheBreakpointIndices(for: [
            .user(text: "hello")
        ])
        #expect(indices == [0])
    }

    @Test("Breakpoints stay within the four the API allows")
    func breakpointBudget() {
        let messages: [AIConversationMessage] = (0..<40).map {
            .user(text: "turn \($0)")
        }
        let conversation = AnthropicProvider.cacheBreakpointIndices(for: messages)
        // Two here plus the one on system leaves headroom under the cap of 4.
        #expect(conversation.count <= 2)
    }

    @Test("An empty conversation asks for no breakpoints")
    func emptyConversation() {
        #expect(AnthropicProvider.cacheBreakpointIndices(for: []).isEmpty)
    }
}

@Suite("OpenAI-compatible caching hints")
struct OpenAICachingTests {
    @Test("Usage is requested so cached tokens are reported while streaming")
    func requestsStreamingUsage() throws {
        let body = OpenAICompatibleProvider.requestBody(
            for: request(messages: [.user(text: "hi")])
        )
        let options = try #require(body["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)
    }

    @Test("Local runtimes are not asked for usage they cannot report")
    func omitsUsageWhenUnsupported() {
        let body = OpenAICompatibleProvider.requestBody(
            for: request(messages: [.user(text: "hi")]),
            reportsUsage: false
        )
        #expect(body["stream_options"] == nil)
    }

    @Test("Stable system text precedes volatile context in the prefix")
    func stablePrefixComesFirst() throws {
        let body = OpenAICompatibleProvider.requestBody(
            for: request(
                system: "stable",
                systemContext: "volatile",
                messages: [.user(text: "hi")]
            )
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "stable")
        #expect(messages[1]["content"] as? String == "volatile")
    }
}

@Suite("Usage reporting")
struct UsageReportingTests {
    private func event(_ json: String) -> SSEEvent {
        SSEEvent(event: nil, data: json)
    }

    @Test("Anthropic input and output counts are merged into one report")
    func anthropicMergesUsage() throws {
        var assembler = AnthropicStreamAssembler()
        _ = assembler.handle(event(
            #"{"type":"message_start","message":{"usage":{"input_tokens":12,"# +
            #""cache_creation_input_tokens":300,"cache_read_input_tokens":1800}}}"#
        ))
        _ = assembler.handle(event(
            #"{"type":"message_delta","usage":{"output_tokens":42}}"#
        ))
        let events = assembler.handle(event(#"{"type":"message_stop"}"#))

        guard case let .usage(usage)? = events.first else {
            Issue.record("expected a usage event before the finish event")
            return
        }
        #expect(usage.inputTokens == 12)
        #expect(usage.outputTokens == 42)
        #expect(usage.cacheCreationTokens == 300)
        #expect(usage.cacheReadTokens == 1800)
        #expect(usage.totalInputTokens == 2112)
    }

    @Test("A provider that reports nothing emits no usage event")
    func silentProviderEmitsNothing() {
        var assembler = AnthropicStreamAssembler()
        let events = assembler.handle(event(#"{"type":"message_stop"}"#))
        #expect(events.count == 1)
        if case .usage = events[0] {
            Issue.record("did not expect a usage event")
        }
    }

    @Test("OpenAI cached tokens are split out of the prompt total")
    func openAISplitsCachedTokens() {
        var assembler = OpenAIStreamAssembler()
        _ = assembler.handle(dataPayload:
            #"{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":50,"# +
            #""prompt_tokens_details":{"cached_tokens":900}}}"#
        )
        let events = assembler.finish()
        let usage = events.compactMap { event -> AITokenUsage? in
            if case let .usage(usage) = event { return usage }
            return nil
        }.first

        #expect(usage?.inputTokens == 100)
        #expect(usage?.cacheReadTokens == 900)
        #expect(usage?.outputTokens == 50)
    }

    @Test("The cached share is the headline number")
    func cachedFraction() {
        let usage = AITokenUsage(
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationTokens: 0,
            cacheReadTokens: 900
        )
        #expect(abs(usage.cachedInputFraction - 0.9) < 0.0001)
        #expect(AITokenUsage().cachedInputFraction == 0)
    }
}
