import Foundation
import Observation

/// A past conversation as listed in the history menu.
public struct AIChatConversationSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
}

/// A conversation as stored on disk: what the transcript shows plus the
/// provider-side messages needed to keep talking where it left off.
struct StoredChatConversation: Codable, Sendable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var messages: [AIChatMessage]
    var providerMessages: [AIConversationMessage]
}

/// On-disk history of past chats.
///
/// Everything is kept in memory and mirrored to a single JSON file, which is
/// small enough at this cap to rewrite atomically on every change.
@MainActor
@Observable
public final class AIChatStore {
    public static let shared = AIChatStore()

    private static let conversationLimit = 60

    private var conversations: [StoredChatConversation] = []
    private var writeTask: Task<Void, Never>?
    private var didLoad = false

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appending(path: "Point", directoryHint: .isDirectory)
                .appending(path: "chats.json")
        }
        load()
    }

    /// Newest first, for the history menu.
    public var summaries: [AIChatConversationSummary] {
        conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .map {
                AIChatConversationSummary(
                    id: $0.id,
                    title: $0.title,
                    updatedAt: $0.updatedAt
                )
            }
    }

    public var isEmpty: Bool { conversations.isEmpty }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let all = try? decoder.decode([StoredChatConversation].self, from: data) {
            conversations = all
            return
        }

        // A single unreadable conversation must not discard the whole history,
        // which is what a plain array decode does. Salvage per entry instead,
        // and keep the original file so a shape change never destroys chats.
        conversations = Self.salvageConversations(from: data, decoder: decoder)
        preserveUnreadableFile()
    }

    /// Decodes entry by entry, keeping every conversation that still parses.
    static func salvageConversations(
        from data: Data,
        decoder: JSONDecoder
    ) -> [StoredChatConversation] {
        guard let elements = try? decoder.decode([AIJSONValue].self, from: data) else {
            return []
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return elements.compactMap { element in
            guard let elementData = try? encoder.encode(element) else { return nil }
            return try? decoder.decode(StoredChatConversation.self, from: elementData)
        }
    }

    /// Moves an unreadable history aside rather than letting the next save
    /// overwrite it.
    private func preserveUnreadableFile() {
        let backupURL = fileURL
            .deletingLastPathComponent()
            .appending(path: "chats-unreadable.json")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    func conversation(id: UUID) -> StoredChatConversation? {
        conversations.first { $0.id == id }
    }

    /// Inserts or updates a conversation. Empty conversations are not stored,
    /// so opening the panel and closing it leaves no trace.
    func save(_ conversation: StoredChatConversation) {
        guard !conversation.messages.isEmpty else {
            remove(id: conversation.id)
            return
        }
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        if conversations.count > Self.conversationLimit {
            conversations = conversations
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.conversationLimit)
                .map { $0 }
        }
        scheduleWrite()
    }

    public func remove(id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        conversations.removeAll { $0.id == id }
        scheduleWrite()
    }

    public func removeAll() {
        guard !conversations.isEmpty else { return }
        conversations = []
        scheduleWrite()
    }

    /// Serializes writes so a burst of streaming updates costs one file write.
    private func scheduleWrite() {
        writeTask?.cancel()
        let snapshot = conversations
        let url = fileURL
        writeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                guard let data = try? encoder.encode(snapshot) else { return }
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    /// Flushes any pending write immediately, for app termination.
    public func flush() async {
        writeTask?.cancel()
        writeTask = nil
        let snapshot = conversations
        let url = fileURL
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }.value
    }
}
