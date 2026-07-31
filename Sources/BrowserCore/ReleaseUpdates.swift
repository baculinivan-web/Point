import Foundation

/// Cross-target request used by Settings to ask the app lifecycle to run its
/// already-throttled update check.
public enum BrowserManualUpdate {
    public static let checkRequested = Notification.Name(
        "BrowserManualUpdateCheckRequested"
    )
    public static let checkFinished = Notification.Name(
        "BrowserManualUpdateCheckFinished"
    )
    public static let statusUserInfoKey = "status"

    public enum CheckStatus: String, Sendable {
        case updateAvailable
        case upToDate
        case checkedRecently
        case unavailable
        case configurationMissing
        case checkInProgress
    }
}

/// Version values accepted from `CFBundleShortVersionString` and GitHub tags.
///
/// GitHub's `releases/latest` endpoint intentionally excludes prereleases, so
/// the app only needs to compare stable numeric versions here.
public struct ReleaseVersion: Sendable, Comparable, Equatable, Hashable,
    CustomStringConvertible {
    public let components: [Int]

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({
            !$0.isEmpty && $0.allSatisfy(\.isNumber)
        }) else {
            return nil
        }

        var parsed = parts.compactMap { Int($0) }
        guard parsed.count == parts.count else { return nil }
        while parsed.count > 1, parsed.last == 0 {
            parsed.removeLast()
        }
        components = parsed
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// All production release-source settings live in one place: the app bundle's
/// Info.plist. Until its placeholders are replaced, automatic checks are
/// deliberately disabled rather than contacting an unverifiable repository.
public struct ReleaseUpdateConfiguration: Sendable, Equatable {
    public static let releasesEndpointKey = "BrowserGitHubReleasesAPIURL"
    public static let notesURLTemplateKey = "BrowserReleaseNotesURLFormat"
    public static let compatibleAssetNameKey = "BrowserReleaseAssetName"

    public let releasesEndpoint: URL?
    public let releaseNotesURLTemplate: String
    public let compatibleAssetName: String

    public init(
        releasesEndpoint: URL?,
        releaseNotesURLTemplate: String,
        compatibleAssetName: String
    ) {
        self.releasesEndpoint = releasesEndpoint
        self.releaseNotesURLTemplate = releaseNotesURLTemplate
        self.compatibleAssetName = compatibleAssetName
    }

    public init(infoDictionary: [String: Any]?) {
        let endpointText = infoDictionary?[Self.releasesEndpointKey] as? String
        let notesTemplate = infoDictionary?[Self.notesURLTemplateKey] as? String
        let assetName = infoDictionary?[Self.compatibleAssetNameKey] as? String
        self.init(
            releasesEndpoint: endpointText.flatMap(URL.init(string:)),
            releaseNotesURLTemplate: notesTemplate ?? "",
            compatibleAssetName: assetName ?? ""
        )
    }

    public static var appBundle: Self {
        Self(infoDictionary: Bundle.main.infoDictionary)
    }

    public var isConfigured: Bool {
        guard let releasesEndpoint,
              releasesEndpoint.scheme == "https",
              releasesEndpoint.host == "api.github.com",
              releasesEndpoint.path.hasSuffix("/releases/latest"),
              !containsPlaceholder(releasesEndpoint.absoluteString),
              compatibleAssetName.lowercased().hasSuffix(".dmg"),
              !containsPlaceholder(compatibleAssetName),
              !releaseNotesURLTemplate.isEmpty,
              !containsPlaceholder(releaseNotesURLTemplate),
              releaseNotesURLTemplate.contains("{version}")
        else {
            return false
        }
        return true
    }

    public func releaseNotesURL(for version: ReleaseVersion) -> URL? {
        guard isConfigured else { return nil }
        let encodedVersion = version.description.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? version.description
        return URL(string: releaseNotesURLTemplate.replacing(
            "{version}",
            with: encodedVersion
        ))
    }

    private func containsPlaceholder(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("REPLACE_WITH")
            || value.localizedCaseInsensitiveContains("YOUR_")
    }
}

public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let downloadURL: URL
}

public struct AvailableRelease: Sendable, Equatable {
    public let version: ReleaseVersion
    public let asset: ReleaseAsset
    public let githubReleaseURL: URL

    public init(version: ReleaseVersion, asset: ReleaseAsset, githubReleaseURL: URL) {
        self.version = version
        self.asset = asset
        self.githubReleaseURL = githubReleaseURL
    }
}

public struct ReleaseHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol ReleaseUpdateFetching: Sendable {
    func fetch(_ url: URL) async throws -> ReleaseHTTPResponse
}

public struct URLSessionReleaseUpdateFetcher: ReleaseUpdateFetching {
    public init() {}

    public func fetch(_ url: URL) async throws -> ReleaseHTTPResponse {
        let (data, response) = try await URLSession.shared.data(from: url)
        return ReleaseHTTPResponse(
            data: data,
            statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
        )
    }
}

public enum ReleaseUpdateError: Error, Equatable {
    case notConfigured
    case invalidResponse
    case unexpectedStatusCode(Int)
    case invalidVersion
    case missingCompatibleAsset
}

/// Small GitHub Releases client. The injected fetcher keeps parsing and
/// compatibility selection testable without making network requests in tests.
public struct ReleaseUpdateService: Sendable {
    private let configuration: ReleaseUpdateConfiguration
    private let fetcher: any ReleaseUpdateFetching

    public init(
        configuration: ReleaseUpdateConfiguration,
        fetcher: any ReleaseUpdateFetching = URLSessionReleaseUpdateFetcher()
    ) {
        self.configuration = configuration
        self.fetcher = fetcher
    }

    public func latestUpdate(
        installedVersion: ReleaseVersion
    ) async throws -> AvailableRelease? {
        guard configuration.isConfigured, let endpoint = configuration.releasesEndpoint else {
            throw ReleaseUpdateError.notConfigured
        }
        let response = try await fetcher.fetch(endpoint)
        guard (200 ... 299).contains(response.statusCode) else {
            throw ReleaseUpdateError.unexpectedStatusCode(response.statusCode)
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: response.data)
        } catch {
            throw ReleaseUpdateError.invalidResponse
        }
        guard let version = ReleaseVersion(release.tagName) else {
            throw ReleaseUpdateError.invalidVersion
        }
        guard version > installedVersion else { return nil }
        guard let asset = release.assets.first(where: {
            $0.name == configuration.compatibleAssetName
                && $0.downloadURL.scheme == "https"
        }) else {
            throw ReleaseUpdateError.missingCompatibleAsset
        }
        guard let githubReleaseURL = URL(string: release.htmlURL) else {
            throw ReleaseUpdateError.invalidResponse
        }
        return AvailableRelease(
            version: version,
            asset: ReleaseAsset(name: asset.name, downloadURL: asset.downloadURL),
            githubReleaseURL: githubReleaseURL
        )
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}
