import Foundation

/// Streaming client for the Anthropic Messages API (`POST /v1/messages`).
public struct AnthropicProvider: AIProvider {
    public static let defaultModel = "claude-opus-5"
    public static let availableModels = [
        "claude-opus-5",
        "claude-sonnet-5",
        "claude-haiku-4-5"
    ]

    private let apiKey: String
    private let baseURL: URL

    public init(apiKey: String, baseURL: URL? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL ?? URL(string: "https://api.anthropic.com")!
    }

    public func streamChat(
        _ request: AIChatRequest
    ) -> AsyncThrowingStream<AIStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AIChatRequest,
        continuation: AsyncThrowingStream<AIStreamEvent, any Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }

        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Sorted keys keep the serialized body byte-identical across launches.
        // Swift hashes strings with a per-process seed, so unsorted dictionaries
        // would reorder `input_schema` properties on every restart — enough to
        // miss a cache entry that is otherwise still warm.
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(for: request),
            options: [.sortedKeys]
        )

        let session = AIProviderHTTP.makeSession()
        defer { session.invalidateAndCancel() }
        let bytes = try await AIProviderHTTP.openStream(urlRequest, session: session)

        var parser = SSEParser()
        var assembler = AnthropicStreamAssembler()
        for try await line in bytes.sseLines {
            try Task.checkCancellation()
            guard let event = parser.consume(line: line) else { continue }
            for streamEvent in assembler.handle(event) {
                continuation.yield(streamEvent)
            }
        }
        if let trailing = parser.flush() {
            for streamEvent in assembler.handle(trailing) {
                continuation.yield(streamEvent)
            }
        }
        for streamEvent in assembler.finish() {
            continuation.yield(streamEvent)
        }
    }

    /// How many blocks may sit between two conversation breakpoints.
    ///
    /// The API walks back at most 20 content blocks from a breakpoint looking
    /// for an existing entry. One agent turn can append more than that — a
    /// dozen tool results in a single message — so a second anchor is placed
    /// well inside the window. Without it the next request's breakpoint finds
    /// nothing and silently misses.
    private static let breakpointBlockSpacing = 12

    static func requestBody(for request: AIChatRequest) -> [String: Any] {
        var messages = request.messages.map(messagePayload(for:))
        for index in cacheBreakpointIndices(for: request.messages) {
            messages[index] = markingLastBlock(messages[index], ttl: nil)
        }

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "messages": messages
        ]

        var tools = request.tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": jsonObject(from: tool.parameters)
            ] as [String: Any]
        }
        let system = systemBlocks(for: request)

        // Render order is tools → system → messages, so one breakpoint on the
        // last stable system block caches the tools with it. When there is no
        // system prompt the marker moves onto the last tool instead.
        //
        // These bytes are identical on every request in every conversation, so
        // they get the hour-long TTL: the doubled write cost is repaid many
        // times over by not re-sending the whole tool schema each turn.
        if !system.stable.isEmpty {
            body["system"] = markedSystem(system)
        } else if !tools.isEmpty {
            tools[tools.count - 1]["cache_control"] = cacheControl(ttl: "1h")
            if !system.volatile.isEmpty {
                body["system"] = [["type": "text", "text": system.volatile]]
            }
        } else if !system.volatile.isEmpty {
            body["system"] = [["type": "text", "text": system.volatile]]
        }

        if !tools.isEmpty {
            body["tools"] = tools
        }
        return body
    }

    private static func systemBlocks(
        for request: AIChatRequest
    ) -> (stable: String, volatile: String) {
        (request.system, request.systemContext)
    }

    private static func markedSystem(
        _ system: (stable: String, volatile: String)
    ) -> [[String: Any]] {
        var blocks: [[String: Any]] = [[
            "type": "text",
            "text": system.stable,
            "cache_control": cacheControl(ttl: "1h")
        ]]
        // The volatile tail sits after the breakpoint, so rewriting it costs
        // only itself rather than the whole prefix in front of it.
        if !system.volatile.isEmpty {
            blocks.append(["type": "text", "text": system.volatile])
        }
        return blocks
    }

    private static func cacheControl(ttl: String?) -> [String: Any] {
        var control: [String: Any] = ["type": "ephemeral"]
        if let ttl { control["ttl"] = ttl }
        return control
    }

    /// Messages whose last content block carries a conversation breakpoint.
    ///
    /// The newest turn always gets one, so the next request can read the whole
    /// conversation up to it — in an agent loop that is most of the prompt.
    /// A second anchor further back keeps the chain inside the lookback window.
    static func cacheBreakpointIndices(for messages: [AIConversationMessage]) -> Set<Int> {
        guard let last = messages.indices.last else { return [] }
        var indices: Set<Int> = [last]

        var blocks = blockCount(of: messages[last])
        var index = last - 1
        while index >= 0 {
            blocks += blockCount(of: messages[index])
            if blocks >= breakpointBlockSpacing {
                indices.insert(index)
                break
            }
            index -= 1
        }
        return indices
    }

    private static func blockCount(of message: AIConversationMessage) -> Int {
        switch message {
        case let .user(_, attachments):
            attachments.filter { $0.kind == .image }.count + 1
        case let .assistant(text, toolCalls):
            (text.isEmpty ? 0 : 1) + toolCalls.count
        case let .toolResults(results):
            results.count
        }
    }

    /// Puts a breakpoint on a message, promoting plain-string content to a
    /// block array because `cache_control` only exists on blocks.
    private static func markingLastBlock(
        _ payload: [String: Any],
        ttl: String?
    ) -> [String: Any] {
        var payload = payload
        var blocks: [[String: Any]]
        if let text = payload["content"] as? String {
            blocks = [["type": "text", "text": text]]
        } else if let existing = payload["content"] as? [[String: Any]] {
            blocks = existing
        } else {
            return payload
        }
        guard !blocks.isEmpty else { return payload }
        blocks[blocks.count - 1]["cache_control"] = cacheControl(ttl: ttl)
        payload["content"] = blocks
        return payload
    }

    private static func messagePayload(for message: AIConversationMessage) -> [String: Any] {
        switch message {
        case let .user(text, attachments):
            guard !attachments.isEmpty else {
                return ["role": "user", "content": text]
            }
            var blocks: [[String: Any]] = attachments.compactMap { attachment in
                guard attachment.kind == .image else { return nil }
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": attachment.mediaType,
                        "data": attachment.base64Data
                    ]
                ]
            }
            blocks.append(["type": "text", "text": textWithFileAttachments(text, attachments)])
            return ["role": "user", "content": blocks]
        case let .assistant(text, toolCalls):
            var blocks: [[String: Any]] = []
            if !text.isEmpty {
                blocks.append(["type": "text", "text": text])
            }
            for call in toolCalls {
                blocks.append([
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": jsonObject(from: call.arguments)
                ])
            }
            return ["role": "assistant", "content": blocks]
        case let .toolResults(results):
            let blocks = results.map { result -> [String: Any] in
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": result.callID,
                    "content": result.content
                ]
                if result.isError {
                    block["is_error"] = true
                }
                return block
            }
            return ["role": "user", "content": blocks]
        }
    }

    /// Text attachments are inlined so they work on every provider, tagged so
    /// the model can tell them apart from the person's own words.
    static func textWithFileAttachments(
        _ text: String,
        _ attachments: [AIAttachment]
    ) -> String {
        let files = attachments.filter { $0.kind == .text && !$0.text.isEmpty }
        guard !files.isEmpty else { return text }
        let rendered = files.map { file in
            """
            <attached_file name="\(file.name)">
            \(file.text)
            </attached_file>
            """
        }.joined(separator: "\n\n")
        return text.isEmpty ? rendered : rendered + "\n\n" + text
    }

    private static func jsonObject(from value: AIJSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .bool(bool): bool
        case let .number(number): number
        case let .string(string): string
        case let .array(items): items.map(jsonObject(from:))
        case let .object(fields): fields.mapValues(jsonObject(from:))
        }
    }
}

/// Reassembles Anthropic SSE events (`content_block_*`, `message_delta`) into
/// harness-level stream events. Tool-use inputs arrive as `input_json_delta`
/// fragments that are buffered until the block stops.
struct AnthropicStreamAssembler {
    private struct PendingToolCall {
        var id: String
        var name: String
        var inputJSON: String
    }

    private var pendingToolCalls: [Int: PendingToolCall] = [:]
    private var stopReason: AIStopReason?
    private var didEmitFinish = false
    /// Input counts arrive on `message_start` and output counts on
    /// `message_delta`, so the two halves are merged before being emitted once.
    private var usage = AITokenUsage()

    mutating func handle(_ event: SSEEvent) -> [AIStreamEvent] {
        guard let data = event.data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AIJSONValue.self, from: data),
              let type = payload["type"]?.stringValue
        else { return [] }

        switch type {
        case "message_start":
            if let reported = payload["message"]?["usage"] {
                merge(usage: reported)
            }
            return []
        case "content_block_start":
            guard let index = payload["index"].flatMap(intValue),
                  let block = payload["content_block"],
                  block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue
            else { return [] }
            pendingToolCalls[index] = PendingToolCall(id: id, name: name, inputJSON: "")
            return []
        case "content_block_delta":
            guard let delta = payload["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
                return [.textDelta(text)]
            case "input_json_delta":
                if let index = payload["index"].flatMap(intValue),
                   let fragment = delta["partial_json"]?.stringValue {
                    pendingToolCalls[index]?.inputJSON += fragment
                }
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let index = payload["index"].flatMap(intValue),
                  let pending = pendingToolCalls.removeValue(forKey: index)
            else { return [] }
            let arguments = pending.inputJSON.isEmpty
                ? AIJSONValue.object([:])
                : AIJSONValue.parse(pending.inputJSON)
            return [.toolCall(
                AIToolCall(id: pending.id, name: pending.name, arguments: arguments)
            )]
        case "message_delta":
            if let reason = payload["delta"]?["stop_reason"]?.stringValue {
                stopReason = Self.stopReason(from: reason)
            }
            if let reported = payload["usage"] {
                merge(usage: reported)
            }
            return []
        case "message_stop":
            didEmitFinish = true
            return usageEvents() + [.finished(stopReason: stopReason ?? .endTurn)]
        case "error":
            let message = payload["error"]?["message"]?.stringValue ?? "stream error"
            didEmitFinish = true
            return [.finished(stopReason: .other(message))]
        default:
            return []
        }
    }

    mutating func finish() -> [AIStreamEvent] {
        guard !didEmitFinish else { return [] }
        didEmitFinish = true
        return usageEvents() + [.finished(stopReason: stopReason ?? .endTurn)]
    }

    private func usageEvents() -> [AIStreamEvent] {
        usage.isEmpty ? [] : [.usage(usage)]
    }

    /// Anthropic reports each field only on the event that knows it, so a
    /// zero here means "not in this event", never "reset to zero".
    private mutating func merge(usage reported: AIJSONValue) {
        func count(_ key: String) -> Int? {
            guard case let .number(number)? = reported[key] else { return nil }
            return Int(number)
        }
        if let value = count("input_tokens") { usage.inputTokens = value }
        if let value = count("output_tokens") { usage.outputTokens = value }
        if let value = count("cache_creation_input_tokens") {
            usage.cacheCreationTokens = value
        }
        if let value = count("cache_read_input_tokens") {
            usage.cacheReadTokens = value
        }
    }

    private func intValue(_ value: AIJSONValue) -> Int? {
        if case let .number(number) = value { return Int(number) }
        return nil
    }

    private static func stopReason(from raw: String) -> AIStopReason {
        switch raw {
        case "end_turn", "stop_sequence": .endTurn
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        case "refusal": .refusal
        default: .other(raw)
        }
    }
}
