import Foundation

public struct SiteOrigin: Hashable, Codable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int?

    public init?(scheme: String, host: String, port: Int? = nil) {
        let normalizedScheme = scheme.lowercased()
        let normalizedHost = host.lowercased()
        guard ["http", "https"].contains(normalizedScheme),
              !normalizedHost.isEmpty
        else { return nil }

        self.scheme = normalizedScheme
        self.host = normalizedHost
        if port == 0
            || (normalizedScheme == "http" && port == 80)
            || (normalizedScheme == "https" && port == 443)
        {
            self.port = nil
        } else {
            self.port = port
        }
    }

    public init?(url: URL?) {
        guard let url,
              let scheme = url.scheme,
              let host = url.host
        else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    public var displayName: String {
        var result = "\(scheme)://\(host)"
        if let port {
            result += ":\(port)"
        }
        return result
    }

    public var allowsPersistentSensitivePermission: Bool {
        scheme == "https"
    }
}

public enum MediaPermissionKind: String, Codable, Sendable, CaseIterable {
    case camera
    case microphone
    case cameraAndMicrophone
}

public enum SitePermissionDecision: String, Codable, Sendable {
    case allow
    case deny
}

public struct StoredSitePermission: Hashable, Codable, Sendable {
    public let origin: SiteOrigin
    public let kind: MediaPermissionKind
    public var decision: SitePermissionDecision

    public init(
        origin: SiteOrigin,
        kind: MediaPermissionKind,
        decision: SitePermissionDecision
    ) {
        self.origin = origin
        self.kind = kind
        self.decision = decision
    }
}

public protocol SitePermissionRepository: Sendable {
    func permissions() async throws -> [StoredSitePermission]

    func decision(
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws -> SitePermissionDecision?

    func save(
        _ decision: SitePermissionDecision,
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws

    func remove(
        for origin: SiteOrigin,
        kind: MediaPermissionKind
    ) async throws

    func removeAll() async throws
}
