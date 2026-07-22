import Foundation

public struct BrowsingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var visitedAt: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        visitedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}

public protocol BrowsingHistoryRepository: Sendable {
    func recent(limit: Int) async throws -> [BrowsingHistoryEntry]

    @discardableResult
    func recordVisit(
        url: URL,
        title: String,
        visitedAt: Date
    ) async throws -> BrowsingHistoryEntry

    func updateTitle(_ title: String, for id: UUID) async throws
    func removeAll() async throws
}
