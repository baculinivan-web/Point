import BrowserCore
import Foundation

public actor FileSitePermissionRepository: SitePermissionRepository {
    private struct Snapshot: Codable {
        var permissions: [StoredSitePermission]
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var cachedPermissions: [StoredSitePermission]?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.fileURL = support
                .appending(path: "Browser", directoryHint: .isDirectory)
                .appending(path: "permissions.json", directoryHint: .notDirectory)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    public func decision(
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws -> SitePermissionDecision? {
        let permissions = try loadIfNeeded()
        return permissions.first {
            $0.origin == origin && $0.kind == kind
        }?.decision
    }

    public func permissions() async throws -> [StoredSitePermission] {
        try loadIfNeeded().sorted {
            if $0.origin.displayName != $1.origin.displayName {
                return $0.origin.displayName < $1.origin.displayName
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    public func save(
        _ decision: SitePermissionDecision,
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws {
        var permissions = try loadIfNeeded()
        let stored = StoredSitePermission(
            origin: origin,
            kind: kind,
            decision: decision
        )
        if let index = permissions.firstIndex(where: {
            $0.origin == origin && $0.kind == kind
        }) {
            permissions[index] = stored
        } else {
            permissions.append(stored)
        }

        try persist(permissions)
    }

    public func remove(
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws {
        var permissions = try loadIfNeeded()
        permissions.removeAll {
            $0.origin == origin && $0.kind == kind
        }
        try persist(permissions)
    }

    public func removeAll() async throws {
        _ = try loadIfNeeded()
        try persist([])
    }

    private func loadIfNeeded() throws -> [StoredSitePermission] {
        if let cachedPermissions {
            return cachedPermissions
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedPermissions = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let permissions = try decoder.decode(Snapshot.self, from: data).permissions
        cachedPermissions = permissions
        return permissions
    }

    private func persist(_ permissions: [StoredSitePermission]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(Snapshot(permissions: permissions))
        try data.write(to: fileURL, options: .atomic)
        cachedPermissions = permissions
    }
}
