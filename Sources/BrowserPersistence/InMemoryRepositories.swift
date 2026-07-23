import BrowserCore
import Foundation

public actor InMemorySessionRepository: SessionRepository {
    private var snapshot: BrowserSessionSnapshot?
    private let persistsWithinLifetime: Bool

    public init(persistsWithinLifetime: Bool = false) {
        self.persistsWithinLifetime = persistsWithinLifetime
    }

    public func load() async throws -> BrowserSessionSnapshot? {
        persistsWithinLifetime ? snapshot : nil
    }

    public func save(_ snapshot: BrowserSessionSnapshot) async throws {
        guard persistsWithinLifetime else { return }
        self.snapshot = snapshot
    }
}

public actor InMemoryBrowsingHistoryRepository: BrowsingHistoryRepository {
    private var entries: [BrowsingHistoryEntry] = []

    public init() {}

    public func recent(limit: Int) async throws -> [BrowsingHistoryEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    @discardableResult
    public func recordVisit(
        url: URL,
        title: String,
        visitedAt: Date
    ) async throws -> BrowsingHistoryEntry {
        let entry = BrowsingHistoryEntry(
            url: url,
            title: title,
            visitedAt: visitedAt
        )
        entries.insert(entry, at: 0)
        return entry
    }

    public func updateTitle(_ title: String, for id: UUID) async throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].title = title
    }

    public func removeVisits(before date: Date) async throws {
        entries.removeAll { $0.visitedAt < date }
    }

    public func removeAll() async throws {
        entries.removeAll()
    }
}

public actor InMemorySitePermissionRepository: SitePermissionRepository {
    private var stored: [StoredSitePermission] = []

    public init() {}

    public func decision(
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws -> SitePermissionDecision? {
        stored.first { $0.origin == origin && $0.kind == kind }?.decision
    }

    public func permissions() async throws -> [StoredSitePermission] {
        stored
    }

    public func save(
        _ decision: SitePermissionDecision,
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws {
        let value = StoredSitePermission(
            origin: origin,
            kind: kind,
            decision: decision
        )
        if let index = stored.firstIndex(where: {
            $0.origin == origin && $0.kind == kind
        }) {
            stored[index] = value
        } else {
            stored.append(value)
        }
    }

    public func remove(
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws {
        stored.removeAll { $0.origin == origin && $0.kind == kind }
    }

    public func removeAll() async throws {
        stored.removeAll()
    }
}
