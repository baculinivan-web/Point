import BrowserCore
import Foundation
import Testing

@Suite("Release updates")
struct ReleaseUpdateTests {
    private let endpoint = URL(string: "https://api.github.com/repos/example/point/releases/latest")!
    private let configuration = ReleaseUpdateConfiguration(
        releasesEndpoint: URL(string: "https://api.github.com/repos/example/point/releases/latest"),
        releaseNotesURLTemplate: "https://example.github.io/point/releases/{version}",
        compatibleAssetName: "Point.dmg"
    )

    @Test("Version comparison accepts GitHub v-tags and pads omitted parts")
    func versionComparison() {
        #expect(ReleaseVersion("v1.2.1")! > ReleaseVersion("1.2")!)
        #expect(ReleaseVersion("1.2")! == ReleaseVersion("1.2.0")!)
        #expect(ReleaseVersion("release-1.2") == nil)
    }

    @Test("Only a newer release with the configured DMG is offered")
    func selectsCompatibleNewerRelease() async throws {
        let service = ReleaseUpdateService(
            configuration: configuration,
            fetcher: StubFetcher(json: """
            {"tag_name":"v1.4.0","html_url":"https://github.com/example/point/releases/tag/v1.4.0","body":"## Changes\\n- Faster checks","assets":[
              {"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
              {"name":"Point.dmg","browser_download_url":"https://example.com/Point.dmg"}
            ]}
            """)
        )

        let update = try await service.latestUpdate(installedVersion: ReleaseVersion("1.3.9")!)
        #expect(update?.version == ReleaseVersion("1.4.0"))
        #expect(update?.asset.name == "Point.dmg")
        #expect(update?.releaseNotes == "## Changes\n- Faster checks")
    }

    @Test("Missing configured asset does not produce an unsafe fallback")
    func rejectsMissingCompatibleAsset() async {
        let service = ReleaseUpdateService(
            configuration: configuration,
            fetcher: StubFetcher(json: """
            {"tag_name":"1.4.0","html_url":"https://github.com/example/point/releases/tag/1.4.0","assets":[
              {"name":"Other.dmg","browser_download_url":"https://example.com/Other.dmg"}
            ]}
            """)
        )

        await #expect(throws: ReleaseUpdateError.missingCompatibleAsset) {
            try await service.latestUpdate(installedVersion: ReleaseVersion("1.3.9")!)
        }
    }

    @Test("Placeholder production values leave checks disabled")
    func placeholdersAreNotConfigured() {
        let placeholder = ReleaseUpdateConfiguration(
            releasesEndpoint: URL(string: "https://api.github.com/repos/REPLACE_WITH_OWNER/REPLACE_WITH_REPOSITORY/releases/latest"),
            releaseNotesURLTemplate: "https://REPLACE_WITH_OWNER.github.io/project/releases/{version}",
            compatibleAssetName: "Point.dmg"
        )
        #expect(!placeholder.isConfigured)
        #expect(configuration.releaseNotesURL(for: ReleaseVersion("1.2.3")!)?.absoluteString == "https://example.github.io/point/releases/1.2.3")
    }
}

private struct StubFetcher: ReleaseUpdateFetching {
    let json: String

    func fetch(_ url: URL) async throws -> ReleaseHTTPResponse {
        #expect(url.scheme == "https")
        return ReleaseHTTPResponse(data: Data(json.utf8), statusCode: 200)
    }
}
