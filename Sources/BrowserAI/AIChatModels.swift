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
public struct AIToolCall: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: AIJSONValue

    public init(id: String, name: String, arguments: AIJSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AIToolResult: Sendable, Equatable {
    public let callID: String
    public let content: String
    public let isError: Bool

    public init(callID: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }
}

/// One message in the provider conversation, assembled by the harness.
public enum AIConversationMessage: Sendable {
    case user(String)
    case assistant(text: String, toolCalls: [AIToolCall])
    case toolResults([AIToolResult])
}

public struct AIChatRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [AIConversationMessage]
    public var tools: [AIToolSpec]
    public var maxTokens: Int

    public init(
        model: String,
        system: String,
        messages: [AIConversationMessage],
        tools: [AIToolSpec],
        maxTokens: Int
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

/// Streaming events emitted by providers while a response is generated.
public enum AIStreamEvent: Sendable {
    case textDelta(String)
    case toolCall(AIToolCall)
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
