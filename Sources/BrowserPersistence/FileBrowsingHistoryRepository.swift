import BrowserCore
import Foundation

public actor FileBrowsingHistoryRepository: BrowsingHistoryRepository {
    private struct Snapshot: Codable {
        let schemaVersion: Int
        var entries: [BrowsingHistoryEntry]
    }

    private let fileURL: URL
    private let retentionLimit: Int
    private let duplicateMergeInterval: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedEntries: [BrowsingHistoryEntry]?

    public init(
        fileURL: URL? = nil,
        retentionLimit: Int = 5_000,
        duplicateMergeInterval: TimeInterval = 30
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.fileURL = support
                .appending(path: "Browser", directoryHint: .isDirectory)
                .appending(path: "history.json", directoryHint: .notDirectory)
        }
        self.retentionLimit = max(1, retentionLimit)
        self.duplicateMergeInterval = max(0, duplicateMergeInterval)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func recent(limit: Int) async throws -> [BrowsingHistoryEntry] {
        guard limit > 0 else { return [] }
        return Array(try loadIfNeeded().prefix(limit))
    }

    @discardableResult
    public func recordVisit(
        url: URL,
        title: String,
        visitedAt: Date = Date()
    ) async throws -> BrowsingHistoryEntry {
        var entries = try loadIfNeeded()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let first = entries.first,
           first.url == url,
           visitedAt.timeIntervalSince(first.visitedAt) >= 0,
           visitedAt.timeIntervalSince(first.visitedAt) <= duplicateMergeInterval {
            var merged = first
            merged.visitedAt = visitedAt
            if !normalizedTitle.isEmpty {
                merged.title = normalizedTitle
            }
            entries[0] = merged
            try persist(entries)
            return merged
        }

        let entry = BrowsingHistoryEntry(
            url: url,
            title: normalizedTitle,
            visitedAt: visitedAt
        )
        entries.insert(entry, at: 0)
        if entries.count > retentionLimit {
            entries.removeLast(entries.count - retentionLimit)
        }
        try persist(entries)
        return entry
    }

    public func updateTitle(_ title: String, for id: UUID) async throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }
        var entries = try loadIfNeeded()
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].title != normalizedTitle
        else { return }
        entries[index].title = normalizedTitle
        try persist(entries)
    }

    public func removeAll() async throws {
        _ = try loadIfNeeded()
        try persist([])
    }

    private func loadIfNeeded() throws -> [BrowsingHistoryEntry] {
        if let cachedEntries {
            return cachedEntries
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedEntries = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else {
            cachedEntries = []
            return []
        }
        let entries = Array(snapshot.entries.prefix(retentionLimit))
        cachedEntries = entries
        return entries
    }

    private func persist(_ entries: [BrowsingHistoryEntry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let snapshot = Snapshot(schemaVersion: 1, entries: entries)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        cachedEntries = entries
    }
}
