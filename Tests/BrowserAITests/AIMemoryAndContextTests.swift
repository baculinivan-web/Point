import Foundation
import Testing
@testable import BrowserAI

@Suite("Memory store")
@MainActor
struct AIMemoryStoreTests {
    private func store() -> AIMemoryStore {
        AIMemoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "memory-tests-\(UUID().uuidString)")
                .appending(path: "memories.json")
        )
    }

    @Test func remembersRecallsAndForgets() {
        let store = store()
        let memory = store.remember("Prefers dark mode and Russian replies")
        #expect(memory != nil)
        #expect(store.recent().count == 1)

        #expect(store.forget(identifier: memory!.shortID))
        #expect(store.isEmpty)
    }

    @Test func repeatedFactRefreshesInsteadOfDuplicating() {
        let store = store()
        store.remember("Works on a browser called Point")
        store.remember("works on a browser called point")
        #expect(store.memories.count == 1)
    }

    @Test func searchRanksByMatchedTerms() {
        let store = store()
        store.remember("Uses Swift and SwiftUI daily")
        store.remember("Likes strong coffee")
        store.remember("Swift package layout matters to them")

        let hits = store.search("swift package")
        #expect(hits.count == 2)
        #expect(hits.first?.text.contains("package") == true)
        #expect(store.search("coffee").count == 1)
    }

    @Test func survivesAReopen() async {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "memory-tests-\(UUID().uuidString)")
            .appending(path: "memories.json")
        let store = AIMemoryStore(fileURL: url)
        store.remember("Remembered across launches")
        await store.flush()

        #expect(AIMemoryStore(fileURL: url).memories.count == 1)
    }
}

@Suite("Context budget")
struct AIContextBudgetTests {
    @Test func growsWithConversationLength() {
        let short = AIContextBudget.estimatedTokens(
            system: "sys",
            messages: [.user(text: "hello")]
        )
        let long = AIContextBudget.estimatedTokens(
            system: "sys",
            messages: [.user(text: String(repeating: "hello ", count: 500))]
        )
        #expect(short > 0)
        #expect(long > short * 10)
    }

    @Test func imagesCostMoreThanTheirBytes() {
        let text = AIContextBudget.estimatedTokens(
            system: "",
            messages: [.user(text: "look")]
        )
        let withImage = AIContextBudget.estimatedTokens(
            system: "",
            messages: [
                .user(
                    text: "look",
                    attachments: [
                        AIAttachment(
                            kind: .image,
                            name: "a.jpg",
                            mediaType: "image/jpeg",
                            data: Data([0x01, 0x02])
                        )
                    ]
                )
            ]
        )
        #expect(withImage > text + 1000)
    }

    @Test func toolResultsCountTowardTheWindow() {
        let usage = AIContextBudget.estimatedTokens(
            system: "",
            messages: [
                .toolResults([
                    AIToolResult(callID: "1", content: String(repeating: "x", count: 3000))
                ])
            ]
        )
        #expect(usage > 900)
    }
}
