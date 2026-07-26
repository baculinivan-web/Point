import Foundation

/// Streaming client for OpenAI-compatible `/chat/completions` endpoints.
/// Also drives Ollama through its built-in OpenAI compatibility layer.
public struct OpenAICompatibleProvider: AIProvider {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    public static let defaultModel = "gpt-5.2"

    private let apiKey: String
    private let baseURL: URL
    private let requiresAPIKey: Bool

    public init(apiKey: String, baseURL: URL, requiresAPIKey: Bool = true) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.requiresAPIKey = requiresAPIKey
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
        guard !requiresAPIKey || !apiKey.isEmpty else {
            throw AIProviderError.missingAPIKey
        }

        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(for: request),
            options: []
        )

        let session = AIProviderHTTP.makeSession()
        defer { session.invalidateAndCancel() }
        let bytes = try await AIProviderHTTP.openStream(urlRequest, session: session)

        var parser = SSEParser()
        var assembler = OpenAIStreamAssembler()
        var sawDone = false
        for try await line in bytes.sseLines {
            try Task.checkCancellation()
            guard let event = parser.consume(line: line) else { continue }
            if event.data == "[DONE]" {
                sawDone = true
                break
            }
            for streamEvent in assembler.handle(dataPayload: event.data) {
                continuation.yield(streamEvent)
            }
        }
        if !sawDone, let trailing = parser.flush(), trailing.data != "[DONE]" {
            for streamEvent in assembler.handle(dataPayload: trailing.data) {
                continuation.yield(streamEvent)
            }
        }
        for streamEvent in assembler.finish() {
            continuation.yield(streamEvent)
        }
    }

    static func requestBody(for request: AIChatRequest) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty {
            messages.append(["role": "system", "content": request.system])
        }
        for message in request.messages {
            switch message {
            case let .user(text, attachments):
                let combinedText = AnthropicProvider.textWithFileAttachments(text, attachments)
                let images = attachments.filter { $0.kind == .image }
                if images.isEmpty {
                    messages.append(["role": "user", "content": combinedText])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": combinedText]]
                    for image in images {
                        parts.append([
                            "type": "image_url",
                            "image_url": [
                                "url": "data:\(image.mediaType);base64,\(image.base64Data)"
                            ]
                        ])
                    }
                    messages.append(["role": "user", "content": parts])
                }
            case let .assistant(text, toolCalls):
                var payload: [String: Any] = ["role": "assistant"]
                payload["content"] = text.isEmpty && !toolCalls.isEmpty ? NSNull() : text
                if !toolCalls.isEmpty {
                    payload["tool_calls"] = toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": Self.argumentsJSON(for: call.arguments)
                            ]
                        ]
                    }
                }
                messages.append(payload)
            case let .toolResults(results):
                for result in results {
                    messages.append([
                        "role": "tool",
                        "tool_call_id": result.callID,
                        "content": result.content
                    ])
                }
            }
        }

        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": messages
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": jsonObject(from: tool.parameters)
                    ]
                ]
            }
        }
        return body
    }

    private static func argumentsJSON(for value: AIJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
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

/// Reassembles `chat.completion.chunk` deltas: text arrives incrementally and
/// tool calls arrive as indexed fragments with partial JSON argument strings.
struct OpenAIStreamAssembler {
    private struct PendingToolCall {
        var id: String
        var name: String
        var argumentsJSON: String
    }

    private var pendingToolCalls: [Int: PendingToolCall] = [:]
    private var finishReason: String?
    private var didFinish = false

    mutating func handle(dataPayload: String) -> [AIStreamEvent] {
        guard let data = dataPayload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AIJSONValue.self, from: data),
              case let .array(choices)? = payload["choices"],
              let choice = choices.first
        else { return [] }

        var events: [AIStreamEvent] = []
        if let delta = choice["delta"] {
            if let text = delta["content"]?.stringValue, !text.isEmpty {
                events.append(.textDelta(text))
            }
            if case let .array(calls)? = delta["tool_calls"] {
                for call in calls {
                    let index = call["index"].flatMap(intValue) ?? 0
                    var pending = pendingToolCalls[index]
                        ?? PendingToolCall(id: "", name: "", argumentsJSON: "")
                    if let id = call["id"]?.stringValue, !id.isEmpty {
                        pending.id = id
                    }
                    if let name = call["function"]?["name"]?.stringValue, !name.isEmpty {
                        pending.name = name
                    }
                    if let fragment = call["function"]?["arguments"]?.stringValue {
                        pending.argumentsJSON += fragment
                    }
                    pendingToolCalls[index] = pending
                }
            }
        }
        if let reason = choice["finish_reason"]?.stringValue {
            finishReason = reason
            events.append(contentsOf: finish())
        }
        return events
    }

    mutating func finish() -> [AIStreamEvent] {
        guard !didFinish else { return [] }
        didFinish = true

        var events: [AIStreamEvent] = []
        for index in pendingToolCalls.keys.sorted() {
            guard let pending = pendingToolCalls[index], !pending.name.isEmpty else { continue }
            let id = pending.id.isEmpty ? "call_\(index)_\(UUID().uuidString)" : pending.id
            let arguments = pending.argumentsJSON.isEmpty
                ? AIJSONValue.object([:])
                : AIJSONValue.parse(pending.argumentsJSON)
            events.append(.toolCall(
                AIToolCall(id: id, name: pending.name, arguments: arguments)
            ))
        }
        pendingToolCalls = [:]

        let stopReason: AIStopReason = switch finishReason {
        case "tool_calls": .toolUse
        case "length": .maxTokens
        case "stop", nil: events.contains(where: isToolCall) ? .toolUse : .endTurn
        case let .some(other): .other(other)
        }
        events.append(.finished(stopReason: stopReason))
        return events
    }

    private func isToolCall(_ event: AIStreamEvent) -> Bool {
        if case .toolCall = event { return true }
        return false
    }

    private func intValue(_ value: AIJSONValue) -> Int? {
        if case let .number(number) = value { return Int(number) }
        return nil
    }
}
