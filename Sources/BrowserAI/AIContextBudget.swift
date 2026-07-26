import Foundation

/// Estimates how much of the model's context a conversation occupies.
///
/// Providers tokenize differently and none of them expose a tokenizer here, so
/// this is a deliberate over-estimate: warning early is useful, warning late is
/// not. Cyrillic and CJK text costs more per character than English, which the
/// divisor accounts for.
public enum AIContextBudget {
    /// Characters per token for mixed-language prose.
    private static let charactersPerToken = 3.0
    /// A downscaled screenshot costs roughly this much on vision models.
    private static let tokensPerImage = 1400

    public static func estimatedTokens(
        system: String,
        messages: [AIConversationMessage]
    ) -> Int {
        var total = tokens(in: system)
        for message in messages {
            switch message {
            case let .user(text, attachments):
                total += tokens(in: text)
                for attachment in attachments {
                    total += attachment.kind == .image
                        ? tokensPerImage
                        : tokens(in: attachment.text)
                }
            case let .assistant(text, toolCalls):
                total += tokens(in: text)
                for call in toolCalls {
                    total += tokens(in: call.name) + 24
                    if let data = try? JSONEncoder().encode(call.arguments) {
                        total += Int(Double(data.count) / charactersPerToken)
                    }
                }
            case let .toolResults(results):
                for result in results {
                    total += tokens(in: result.content) + 8
                }
            }
        }
        return total
    }

    static func tokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charactersPerToken).rounded(.up))
    }
}

public extension AIProviderKind {
    /// Context window used when the model is not otherwise known.
    var defaultContextLimit: Int {
        switch self {
        case .anthropic: 200_000
        case .openAICompatible: 128_000
        // Ollama defaults to a small window unless the user raised num_ctx.
        case .ollama: 8_192
        }
    }
}
