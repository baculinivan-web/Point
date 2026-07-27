import Foundation
import Observation

/// A fact the chat chose to keep across conversations.
public struct AIMemory: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Short form used in the tool output and the system prompt.
    public var shortID: String { String(id.uuidString.prefix(8)) }
}

/// Memories that outlive a single chat.
///
/// Deliberately a flat list of short notes: the model writes them, searches
/// them, and deletes them through tools, so structure would only get in the way.
@MainActor
@Observable
public final class AIMemoryStore {
    public static let shared = AIMemoryStore()

    private static let memoryLimit = 500
    private static let textLimit = 2000

    public private(set) var memories: [AIMemory] = []

    private let fileURL: URL
    private var writeTask: Task<Void, Never>?

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
                .appending(path: "memories.json")
        }
        load()
    }

    public var isEmpty: Bool { memories.isEmpty }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let all = try? decoder.decode([AIMemory].self, from: data) {
            memories = all
            return
        }
        // Keep whatever still parses rather than dropping every memory.
        guard let elements = try? decoder.decode([AIJSONValue].self, from: data) else {
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        memories = elements.compactMap { element in
            guard let elementData = try? encoder.encode(element) else { return nil }
            return try? decoder.decode(AIMemory.self, from: elementData)
        }
    }

    @discardableResult
    public func remember(_ text: String) -> AIMemory? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clipped = String(trimmed.prefix(Self.textLimit))

        // Re-remembering the same fact refreshes it instead of duplicating.
        if let index = memories.firstIndex(where: {
            $0.text.caseInsensitiveCompare(clipped) == .orderedSame
        }) {
            memories[index].updatedAt = Date()
            scheduleWrite()
            return memories[index]
        }

        let memory = AIMemory(text: clipped)
        memories.append(memory)
        if memories.count > Self.memoryLimit {
            memories = memories
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.memoryLimit)
                .map { $0 }
        }
        scheduleWrite()
        return memory
    }

    public func recent(limit: Int = 20) -> [AIMemory] {
        memories.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).map { $0 }
    }

    /// Ranks by how many query terms a memory contains, newest first on ties.
    public func search(_ query: String, limit: Int = 10) -> [AIMemory] {
        let terms = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return recent(limit: limit) }

        var scored: [(memory: AIMemory, score: Int)] = []
        for memory in memories {
            let text = memory.text.lowercased()
            let score = terms.reduce(into: 0) { total, term in
                if text.contains(term) { total += 1 }
            }
            if score > 0 { scored.append((memory, score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.memory.updatedAt > rhs.memory.updatedAt
        }
        return scored.prefix(limit).map(\.memory)
    }

    /// Accepts a full UUID or the short prefix shown to the model.
    @discardableResult
    public func forget(identifier: String) -> Bool {
        let needle = identifier.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        guard let index = memories.firstIndex(where: {
            $0.id.uuidString.lowercased() == needle
                || $0.shortID.lowercased() == needle
        }) else { return false }
        memories.remove(at: index)
        scheduleWrite()
        return true
    }

    public func forgetAll() {
        guard !memories.isEmpty else { return }
        memories = []
        scheduleWrite()
    }

    private func scheduleWrite() {
        writeTask?.cancel()
        let snapshot = memories
        let url = fileURL
        writeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: url)
        }
    }

    public func flush() async {
        writeTask?.cancel()
        writeTask = nil
        await Self.write(memories, to: fileURL)
    }

    private static func write(_ memories: [AIMemory], to url: URL) async {
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(memories) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }.value
    }
}
