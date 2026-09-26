import Foundation
import Testing

@testable import BrowserAI

@Suite("Assistant Keychain loading")
@MainActor
struct AIChatKeychainLoadingTests {
    @Test("Browser settings initialization does not read secrets")
    func initializationDoesNotReadKeychain() {
        var reads = 0
        let settings = AIChatSettings(
            readAPIKey: { _ in reads += 1; return "saved-key" },
            writeAPIKey: { _, _ in Issue.record("Unexpected Keychain write") }
        )
        #expect(reads == 0)
        #expect(settings.anthropicAPIKey.isEmpty)
        #expect(settings.openAIAPIKey.isEmpty)
    }

    @Test("Explicit loading preserves saved keys without rewriting them")
    func explicitLoadReadsOnce() {
        var accounts: [String] = []
        var writes: [String] = []
        let settings = AIChatSettings(
            readAPIKey: { account in accounts.append(account); return "saved-\(account)" },
            writeAPIKey: { value, _ in writes.append(value) }
        )
        settings.loadAPIKeysIfNeeded()
        settings.loadAPIKeysIfNeeded()
        #expect(accounts == ["anthropic-api-key", "openai-api-key"])
        #expect(settings.anthropicAPIKey == "saved-anthropic-api-key")
        #expect(settings.openAIAPIKey == "saved-openai-api-key")
        #expect(writes.isEmpty)
        settings.openAIAPIKey = "replacement-key"
        #expect(writes == ["replacement-key"])
    }

    @Test("An unavailable secret is never overwritten during loading")
    func unavailableKeyIsPreserved() {
        let settings = AIChatSettings(
            readAPIKey: { _ in nil },
            writeAPIKey: { _, _ in Issue.record("Unavailable keys must not be deleted") }
        )
        settings.loadAPIKeysIfNeeded()
        #expect(settings.anthropicAPIKey.isEmpty)
        #expect(settings.openAIAPIKey.isEmpty)
    }
}
