import BrowserCore
import Foundation

/// A JSON value that can be sent to and received from model providers.
/// Tool inputs arrive as arbitrary JSON, so the type must be fully dynamic
/// while staying Sendable for Swift 6 concurrency.
public enum AIJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AIJSONValue])
    case object([String: AIJSONValue])

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var objectValue: [String: AIJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> AIJSONValue? {
        objectValue?[key]
    }
}

extension AIJSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AIJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AIJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public static func parse(_ text: String) -> AIJSONValue {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(AIJSONValue.self, from: data)
        else { return .object([:]) }
        return value
    }
}

/// The provider backing the assistant.
public enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAICompatible
    case ollama

    public var id: String { rawValue }
}

/// A tool the model may call. The schema is plain JSON Schema.
public struct AIToolSpec: Sendable {
    public let name: String
    public let description: String
    public let parameters: AIJSONValue

    public init(name: String, description: String, parameters: AIJSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A single tool invocation requested by the model.
public struct AIToolCall: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let arguments: AIJSONValue

    public init(id: String, name: String, arguments: AIJSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// What a tool hands back: text for the model, plus any images it produced.
///
/// Images ride along as a follow-up user message rather than inside the tool
/// result, because only some providers accept image blocks in tool results.
public struct AIToolOutput: Sendable {
    public var text: String
    public var attachments: [AIAttachment]

    public init(text: String, attachments: [AIAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }
}

public struct AIToolResult: Sendable, Equatable, Codable {
    public let callID: String
    public let content: String
    public let isError: Bool

    public init(callID: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }
}

/// A file the person attached to a message.
///
/// Images travel to the model as image blocks; everything else is reduced to
/// text on the browser side so it works with any provider.
public struct AIAttachment: Identifiable, Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case image
        case text
    }

    public let id: UUID
    public let kind: Kind
    public let name: String
    /// IANA media type, e.g. `image/png`. Empty for text attachments.
    public let mediaType: String
    /// Image bytes, already downscaled. Empty for text attachments.
    public let data: Data
    /// Extracted text. Empty for image attachments.
    public let text: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        mediaType: String = "",
        data: Data = Data(),
        text: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mediaType = mediaType
        self.data = data
        self.text = text
    }

    public var base64Data: String { data.base64EncodedString() }
}

/// One message in the provider conversation, assembled by the harness.
public enum AIConversationMessage: Sendable, Codable {
    case user(text: String, attachments: [AIAttachment] = [])
    case assistant(text: String, toolCalls: [AIToolCall])
    case toolResults([AIToolResult])
}

public struct AIChatRequest: Sendable {
    public var model: String
    /// The stable half of the system prompt. Byte-identical across every
    /// request, which is what makes it cacheable.
    public var system: String
    /// System text that changes between requests — memories, and anything else
    /// derived from mutable state. Kept out of `system` so a change here does
    /// not invalidate the cached tools+prompt prefix in front of it.
    public var systemContext: String
    public var messages: [AIConversationMessage]
    public var tools: [AIToolSpec]
    public var maxTokens: Int

    public init(
        model: String,
        system: String,
        systemContext: String = "",
        messages: [AIConversationMessage],
        tools: [AIToolSpec],
        maxTokens: Int
    ) {
        self.model = model
        self.system = system
        self.systemContext = systemContext
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

/// What one request cost, split by how the input was billed.
///
/// Cache reads are roughly a tenth the price of fresh input and cache writes
/// are a small premium over it, so the split — not the total — is what says
/// whether caching is actually paying off.
public struct AITokenUsage: Sendable, Equatable {
    /// Input processed at full price.
    public var inputTokens: Int
    public var outputTokens: Int
    /// Input written into the cache this request.
    public var cacheCreationTokens: Int
    /// Input served from the cache this request.
    public var cacheReadTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var isEmpty: Bool {
        inputTokens == 0 && outputTokens == 0
            && cacheCreationTokens == 0 && cacheReadTokens == 0
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        AITokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens
        )
    }

    /// Total input, however it was billed.
    public var totalInputTokens: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Share of input that came from the cache — the headline number.
    public var cachedInputFraction: Double {
        guard totalInputTokens > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(totalInputTokens)
    }
}

/// Streaming events emitted by providers while a response is generated.
public enum AIStreamEvent: Sendable {
    case textDelta(String)
    case toolCall(AIToolCall)
    /// Billing breakdown for the request, once the provider reports it.
    case usage(AITokenUsage)
    case finished(stopReason: AIStopReason)
}

public enum AIStopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal
    case other(String)
}

public enum AIProviderError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case http(status: Int, message: String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            BrowserLocalization.string("ai_error_missing_key")
        case .invalidResponse:
            BrowserLocalization.string("ai_error_invalid_response")
        case let .http(status, message):
            message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case let .network(message):
            message
        }
    }
}
