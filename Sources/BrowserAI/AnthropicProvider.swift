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
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(for: request),
            options: []
        )

        let session = AIProviderHTTP.makeSession()
        defer { session.invalidateAndCancel() }
        let bytes = try await AIProviderHTTP.openStream(urlRequest, session: session)

        var parser = SSEParser()
        var assembler = AnthropicStreamAssembler()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = parser.consume(line: line) else { continue }
            for streamEvent in assembler.handle(event) {
                continuation.yield(streamEvent)
            }
        }
        if let final = assembler.finish() {
            continuation.yield(final)
        }
    }

    static func requestBody(for request: AIChatRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "messages": request.messages.map(messagePayload(for:))
        ]
        if !request.system.isEmpty {
            body["system"] = request.system
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": jsonObject(from: tool.parameters)
                ]
            }
        }
        return body
    }

    private static func messagePayload(for message: AIConversationMessage) -> [String: Any] {
        switch message {
        case let .user(text):
            return ["role": "user", "content": text]
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

    mutating func handle(_ event: SSEEvent) -> [AIStreamEvent] {
        guard let data = event.data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AIJSONValue.self, from: data),
              let type = payload["type"]?.stringValue
        else { return [] }

        switch type {
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
            return []
        case "message_stop":
            didEmitFinish = true
            return [.finished(stopReason: stopReason ?? .endTurn)]
        case "error":
            let message = payload["error"]?["message"]?.stringValue ?? "stream error"
            didEmitFinish = true
            return [.finished(stopReason: .other(message))]
        default:
            return []
        }
    }

    mutating func finish() -> AIStreamEvent? {
        guard !didEmitFinish else { return nil }
        didEmitFinish = true
        return .finished(stopReason: stopReason ?? .endTurn)
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
