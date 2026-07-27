import Foundation
import Testing

@testable import BrowserAutomation

@Suite("Label matching")
struct AgentPhraseMatcherTests {
    @Test("Whole words match regardless of case, accents, or punctuation")
    func wholeWords() {
        #expect(AgentPhraseMatcher.matches("Delete", anyOf: ["delete"]))
        #expect(AgentPhraseMatcher.matches("DELETE ACCOUNT", anyOf: ["delete"]))
        #expect(AgentPhraseMatcher.matches("Save / Delete", anyOf: ["delete"]))
        #expect(AgentPhraseMatcher.matches("Удалить", anyOf: ["удалить"]))
    }

    @Test("A word inside another word does not match")
    func noSubstringMatches() {
        // The regression this whole type exists for.
        #expect(!AgentPhraseMatcher.matches("Facebook", anyOf: ["book"]))
        #expect(!AgentPhraseMatcher.matches("Shipping address", anyOf: ["pin"]))
        #expect(!AgentPhraseMatcher.matches("Postal code", anyOf: ["post"]))
        #expect(!AgentPhraseMatcher.matches("Sender name", anyOf: ["send"]))
        #expect(!AgentPhraseMatcher.matches("Удалённый доступ", anyOf: ["удалить"]))
    }

    @Test("Multi-word phrases must appear as consecutive words")
    func consecutiveWords() {
        #expect(AgentPhraseMatcher.matches("Place order now", anyOf: ["place order"]))
        #expect(!AgentPhraseMatcher.matches(
            "Place your first order",
            anyOf: ["place order"]
        ))
    }

    @Test("Empty input matches nothing")
    func emptyInput() {
        #expect(!AgentPhraseMatcher.matches("", anyOf: ["delete"]))
        #expect(!AgentPhraseMatcher.matches("Delete", anyOf: []))
        #expect(!AgentPhraseMatcher.matches("Delete", anyOf: ["   "]))
    }
}
