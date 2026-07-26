import Foundation
import Observation

/// Persisted assistant configuration shared by every window.
/// API keys live in the keychain; everything else in UserDefaults.
@MainActor
@Observable
public final class AIChatSettings {
    public static let shared = AIChatSettings()

    private enum DefaultsKey {
        static let provider = "AIChatProvider"
        static let anthropicModel = "AIChatAnthropicModel"
        static let openAIModel = "AIChatOpenAIModel"
        static let openAIBaseURL = "AIChatOpenAIBaseURL"
        static let ollamaModel = "AIChatOllamaModel"
        static let includesPageContext = "AIChatIncludesPageContext"
        static let panelWidth = "AIChatPanelWidth"
    }

    public static let panelWidthRange: ClosedRange<Double> = 300...760

    private enum KeychainAccount {
        static let anthropic = "anthropic-api-key"
        static let openAI = "openai-api-key"
    }

    public var provider: AIProviderKind {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: DefaultsKey.provider)
        }
    }

    public var anthropicModel: String {
        didSet {
            UserDefaults.standard.set(anthropicModel, forKey: DefaultsKey.anthropicModel)
        }
    }

    public var openAIModel: String {
        didSet {
            UserDefaults.standard.set(openAIModel, forKey: DefaultsKey.openAIModel)
        }
    }

    public var openAIBaseURLText: String {
        didSet {
            UserDefaults.standard.set(openAIBaseURLText, forKey: DefaultsKey.openAIBaseURL)
        }
    }

    public var ollamaModel: String {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: DefaultsKey.ollamaModel)
        }
    }

    /// Width of the docked chat panel, adjustable by dragging its edge.
    public var panelWidth: Double {
        didSet {
            let clamped = min(max(panelWidth, Self.panelWidthRange.lowerBound),
                              Self.panelWidthRange.upperBound)
            if clamped != panelWidth {
                panelWidth = clamped
                return
            }
            UserDefaults.standard.set(panelWidth, forKey: DefaultsKey.panelWidth)
        }
    }

    /// Whether the active page is shared with the model by default.
    public var includesPageContext: Bool {
        didSet {
            UserDefaults.standard.set(
                includesPageContext,
                forKey: DefaultsKey.includesPageContext
            )
        }
    }

    public var anthropicAPIKey: String {
        didSet {
            KeychainStore.set(anthropicAPIKey, for: KeychainAccount.anthropic)
        }
    }

    public var openAIAPIKey: String {
        didSet {
            KeychainStore.set(openAIAPIKey, for: KeychainAccount.openAI)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        provider = defaults.string(forKey: DefaultsKey.provider)
            .flatMap(AIProviderKind.init(rawValue:)) ?? .anthropic
        anthropicModel = defaults.string(forKey: DefaultsKey.anthropicModel)
            ?? AnthropicProvider.defaultModel
        openAIModel = defaults.string(forKey: DefaultsKey.openAIModel)
            ?? OpenAICompatibleProvider.defaultModel
        openAIBaseURLText = defaults.string(forKey: DefaultsKey.openAIBaseURL)
            ?? OpenAICompatibleProvider.defaultBaseURL.absoluteString
        ollamaModel = defaults.string(forKey: DefaultsKey.ollamaModel) ?? ""
        includesPageContext = defaults.object(
            forKey: DefaultsKey.includesPageContext
        ) as? Bool ?? true
        let storedWidth = defaults.object(forKey: DefaultsKey.panelWidth) as? Double ?? 380
        panelWidth = min(
            max(storedWidth, Self.panelWidthRange.lowerBound),
            Self.panelWidthRange.upperBound
        )
        anthropicAPIKey = KeychainStore.string(for: KeychainAccount.anthropic) ?? ""
        openAIAPIKey = KeychainStore.string(for: KeychainAccount.openAI) ?? ""
    }

    public var activeModelName: String {
        switch provider {
        case .anthropic: anthropicModel
        case .openAICompatible: openAIModel
        case .ollama: ollamaModel
        }
    }

    /// Whether enough configuration exists to send a message at all.
    public var isConfigured: Bool {
        switch provider {
        case .anthropic:
            !anthropicAPIKey.isEmpty
        case .openAICompatible:
            !openAIAPIKey.isEmpty && URL(string: openAIBaseURLText) != nil
        case .ollama:
            !ollamaModel.isEmpty
        }
    }

    public func makeProvider() -> (any AIProvider)? {
        switch provider {
        case .anthropic:
            guard !anthropicAPIKey.isEmpty else { return nil }
            return AnthropicProvider(apiKey: anthropicAPIKey)
        case .openAICompatible:
            guard let url = URL(string: openAIBaseURLText), !openAIAPIKey.isEmpty else {
                return nil
            }
            return OpenAICompatibleProvider(apiKey: openAIAPIKey, baseURL: url)
        case .ollama:
            guard !ollamaModel.isEmpty else { return nil }
            return OpenAICompatibleProvider(
                apiKey: "",
                baseURL: OllamaRuntime.openAICompatibleBaseURL,
                requiresAPIKey: false
            )
        }
    }

    /// Whether the selected model can read attached images.
    public var supportsImageAttachments: Bool {
        Self.supportsImages(provider: provider, model: ollamaModel)
    }

    /// Anthropic and mainstream OpenAI-compatible models are multimodal; local
    /// Ollama models mostly are not, so the model name has to say so.
    public nonisolated static func supportsImages(
        provider: AIProviderKind,
        model: String
    ) -> Bool {
        switch provider {
        case .anthropic, .openAICompatible:
            return true
        case .ollama:
            let name = model.lowercased()
            let visionFamilies = [
                "llava", "vision", "vl:", "-vl", "vl-", "minicpm-v", "moondream",
                "gemma3", "mistral-small3", "granite3.2-vision"
            ]
            // A bare `…vl` tag such as "qwen2.5vl" carries no separator.
            return visionFamilies.contains { name.contains($0) }
                || name.hasSuffix("vl")
        }
    }

    public var maxTokens: Int {
        switch provider {
        case .anthropic: 64000
        case .openAICompatible: 16000
        case .ollama: 4096
        }
    }
}
