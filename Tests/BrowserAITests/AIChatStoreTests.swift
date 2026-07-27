import Foundation
import Testing
@testable import BrowserAI

@Suite("Chat history storage")
@MainActor
struct AIChatStoreTests {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "chat-store-tests-\(UUID().uuidString)")
            .appending(path: "chats.json")
    }

    private func conversation(
        title: String,
        text: String = "hello"
    ) -> StoredChatConversation {
        StoredChatConversation(
            id: UUID(),
            title: title,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            messages: [AIChatMessage(role: .user, text: text)],
            providerMessages: [.user(text: text)]
        )
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func savedConversationsReloadFromDisk() async throws {
        let url = temporaryFileURL()
        let store = AIChatStore(fileURL: url)
        store.save(conversation(title: "first"))
        await store.flush()

        let reopened = AIChatStore(fileURL: url)
        #expect(reopened.summaries.map(\.title) == ["first"])
    }

    @Test func emptyConversationsAreNotStored() async throws {
        let url = temporaryFileURL()
        let store = AIChatStore(fileURL: url)
        var empty = conversation(title: "empty")
        empty.messages = []
        store.save(empty)
        await store.flush()

        #expect(AIChatStore(fileURL: url).summaries.isEmpty)
    }

    /// The regression that lost real chats: one entry written by an older
    /// build made the whole array fail to decode, and the next save then
    /// overwrote the file.
    @Test func oneUnreadableEntryDoesNotDiscardTheRest() throws {
        let good = conversation(title: "keep me")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodJSON = String(data: try encoder.encode(good), encoding: .utf8)!
        // An entry in a shape this build no longer understands.
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"legacy","updatedAt":"2026-01-01T00:00:00Z",
         "messages":[{"id":"\(UUID().uuidString)","role":{"user":{}},"text":"old"}],
         "providerMessages":[]}
        """
        let mixed = Data("[\(legacyJSON),\(goodJSON)]".utf8)

        let salvaged = AIChatStore.salvageConversations(from: mixed, decoder: decoder())
        #expect(salvaged.map(\.title) == ["keep me"])
    }

    @Test func unreadableFileIsPreservedInsteadOfOverwritten() async throws {
        let url = temporaryFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("[{\"totally\":\"unexpected\"}]".utf8).write(to: url)

        let store = AIChatStore(fileURL: url)
        #expect(store.summaries.isEmpty)

        store.save(conversation(title: "new"))
        await store.flush()

        let backup = url.deletingLastPathComponent()
            .appending(path: "chats-unreadable.json")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(AIChatStore(fileURL: url).summaries.map(\.title) == ["new"])
    }

    @Test func removingAConversationPersists() async throws {
        let url = temporaryFileURL()
        let store = AIChatStore(fileURL: url)
        let keep = conversation(title: "keep")
        let drop = conversation(title: "drop")
        store.save(keep)
        store.save(drop)
        store.remove(id: drop.id)
        await store.flush()

        #expect(AIChatStore(fileURL: url).summaries.map(\.title) == ["keep"])
    }

    @Test func summariesAreNewestFirst() async throws {
        let url = temporaryFileURL()
        let store = AIChatStore(fileURL: url)
        var older = conversation(title: "older")
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = conversation(title: "newer")
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        store.save(older)
        store.save(newer)

        #expect(store.summaries.map(\.title) == ["newer", "older"])
    }
}
