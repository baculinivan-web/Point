import BrowserCore
import Foundation
import SwiftData

@Model
final class SessionSnapshotRecord {
    @Attribute(.unique) var windowID: UUID
    var payload: Data
    var updatedAt: Date

    init(windowID: UUID, payload: Data, updatedAt: Date = Date()) {
        self.windowID = windowID
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

@Model
final class BrowsingHistoryRecord {
    @Attribute(.unique) var id: UUID
    var url: URL
    var title: String
    var visitedAt: Date

    init(id: UUID, url: URL, title: String, visitedAt: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}

public final class BrowserPersistenceController: @unchecked Sendable {
    public static let primaryWindowID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!

    private let container: ModelContainer
    private let legacySessionURL: URL
    private let legacyHistoryURL: URL

    public init(storeURL: URL? = nil, legacyDirectoryURL: URL? = nil) throws {
        let support = legacyDirectoryURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appending(path: "Browser", directoryHint: .isDirectory)
        legacySessionURL = support.appending(path: "session.json")
        legacyHistoryURL = support.appending(path: "history.json")

        let schema = Schema([
            SessionSnapshotRecord.self,
            BrowsingHistoryRecord.self
        ])
        let configuration: ModelConfiguration
        if let storeURL {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                "Browser",
                schema: schema,
                url: storeURL
            )
        } else {
            configuration = ModelConfiguration(
                "Browser",
                schema: schema
            )
        }
        container = try ModelContainer(
            for: schema,
            configurations: configuration
        )
    }

    public func sessionRepository(
        windowID: UUID,
        migratesLegacySession: Bool = false
    ) -> SwiftDataSessionRepository {
        SwiftDataSessionRepository(
            container: container,
            windowID: windowID,
            legacyFileURL: migratesLegacySession ? legacySessionURL : nil
        )
    }

    public func browsingHistoryRepository() -> SwiftDataBrowsingHistoryRepository {
        SwiftDataBrowsingHistoryRepository(
            container: container,
            legacyFileURL: legacyHistoryURL
        )
    }
}

public actor SwiftDataSessionRepository: SessionRepository {
    private let container: ModelContainer
    private let windowID: UUID
    private let legacyFileURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var didAttemptMigration = false

    fileprivate init(
        container: ModelContainer,
        windowID: UUID,
        legacyFileURL: URL?
    ) {
        self.container = container
        self.windowID = windowID
        self.legacyFileURL = legacyFileURL
    }

    public func load() async throws -> BrowserSessionSnapshot? {
        try migrateLegacyIfNeeded()
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<SessionSnapshotRecord>())
        guard let record = records.first(where: { $0.windowID == windowID }) else {
            return nil
        }
        return try decoder.decode(BrowserSessionSnapshot.self, from: record.payload)
    }

    public func save(_ snapshot: BrowserSessionSnapshot) async throws {
        let context = ModelContext(container)
        let data = try encoder.encode(snapshot)
        let records = try context.fetch(FetchDescriptor<SessionSnapshotRecord>())
        if let record = records.first(where: { $0.windowID == windowID }) {
            record.payload = data
            record.updatedAt = Date()
        } else {
            context.insert(
                SessionSnapshotRecord(windowID: windowID, payload: data)
            )
        }
        try context.save()
    }

    private func migrateLegacyIfNeeded() throws {
        guard !didAttemptMigration else { return }
        didAttemptMigration = true
        guard let legacyFileURL,
              FileManager.default.fileExists(atPath: legacyFileURL.path)
        else { return }

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<SessionSnapshotRecord>())
        guard !records.contains(where: { $0.windowID == windowID }) else { return }

        let data = try Data(contentsOf: legacyFileURL)
        do {
            _ = try decoder.decode(BrowserSessionSnapshot.self, from: data)
        } catch {
            archiveLegacyFile(legacyFileURL, suffix: "corrupt")
            return
        }
        context.insert(SessionSnapshotRecord(windowID: windowID, payload: data))
        try context.save()
        archiveLegacyFile(legacyFileURL)
    }
}

public actor SwiftDataBrowsingHistoryRepository: BrowsingHistoryRepository {
    private struct LegacySnapshot: Codable {
        let schemaVersion: Int
        var entries: [BrowsingHistoryEntry]
    }

    private let container: ModelContainer
    private let legacyFileURL: URL?
    private let retentionLimit: Int
    private let duplicateMergeInterval: TimeInterval
    private var didAttemptMigration = false

    fileprivate init(
        container: ModelContainer,
        legacyFileURL: URL?,
        retentionLimit: Int = 5_000,
        duplicateMergeInterval: TimeInterval = 30
    ) {
        self.container = container
        self.legacyFileURL = legacyFileURL
        self.retentionLimit = max(1, retentionLimit)
        self.duplicateMergeInterval = max(0, duplicateMergeInterval)
    }

    public func recent(limit: Int) async throws -> [BrowsingHistoryEntry] {
        guard limit > 0 else { return [] }
        try migrateLegacyIfNeeded()
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<BrowsingHistoryRecord>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(Self.entry)
    }

    @discardableResult
    public func recordVisit(
        url: URL,
        title: String,
        visitedAt: Date
    ) async throws -> BrowsingHistoryEntry {
        try migrateLegacyIfNeeded()
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<BrowsingHistoryRecord>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let latest = try context.fetch(descriptor).first,
           latest.url == url,
           visitedAt.timeIntervalSince(latest.visitedAt) >= 0,
           visitedAt.timeIntervalSince(latest.visitedAt) <= duplicateMergeInterval {
            latest.visitedAt = visitedAt
            if !normalizedTitle.isEmpty {
                latest.title = normalizedTitle
            }
            try context.save()
            return Self.entry(latest)
        }

        let record = BrowsingHistoryRecord(
            id: UUID(),
            url: url,
            title: normalizedTitle,
            visitedAt: visitedAt
        )
        context.insert(record)
        try trimIfNeeded(context)
        try context.save()
        return Self.entry(record)
    }

    public func updateTitle(_ title: String, for id: UUID) async throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<BrowsingHistoryRecord>())
        guard let record = records.first(where: { $0.id == id }) else { return }
        record.title = normalizedTitle
        try context.save()
    }

    public func removeVisits(before date: Date) async throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<BrowsingHistoryRecord>())
        for record in records where record.visitedAt < date {
            context.delete(record)
        }
        try context.save()
    }

    public func removeAll() async throws {
        let context = ModelContext(container)
        try context.delete(model: BrowsingHistoryRecord.self)
        try context.save()
    }

    private func migrateLegacyIfNeeded() throws {
        guard !didAttemptMigration else { return }
        didAttemptMigration = true
        guard let legacyFileURL,
              FileManager.default.fileExists(atPath: legacyFileURL.path)
        else { return }

        let context = ModelContext(container)
        guard try context.fetchCount(
            FetchDescriptor<BrowsingHistoryRecord>()
        ) == 0 else { return }

        let data = try Data(contentsOf: legacyFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: LegacySnapshot
        do {
            snapshot = try decoder.decode(LegacySnapshot.self, from: data)
        } catch {
            archiveLegacyFile(legacyFileURL, suffix: "corrupt")
            return
        }
        guard snapshot.schemaVersion == 1 else {
            archiveLegacyFile(legacyFileURL, suffix: "unsupported")
            return
        }
        for entry in snapshot.entries.prefix(retentionLimit) {
            context.insert(
                BrowsingHistoryRecord(
                    id: entry.id,
                    url: entry.url,
                    title: entry.title,
                    visitedAt: entry.visitedAt
                )
            )
        }
        try context.save()
        archiveLegacyFile(legacyFileURL)
    }

    private func trimIfNeeded(_ context: ModelContext) throws {
        var descriptor = FetchDescriptor<BrowsingHistoryRecord>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchOffset = retentionLimit
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
    }

    private static func entry(
        _ record: BrowsingHistoryRecord
    ) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(
            id: record.id,
            url: record.url,
            title: record.title,
            visitedAt: record.visitedAt
        )
    }
}

private func archiveLegacyFile(
    _ fileURL: URL,
    suffix: String = "migrated"
) {
    let archivedURL = fileURL.appendingPathExtension(suffix)
    try? FileManager.default.removeItem(at: archivedURL)
    try? FileManager.default.moveItem(at: fileURL, to: archivedURL)
}
