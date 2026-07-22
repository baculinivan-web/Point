import BrowserCore
import Foundation
import Testing

@Suite("Site origins")
struct SiteOriginTests {
    @Test("Scheme, host, and default port are normalized")
    func normalization() {
        let origin = SiteOrigin(
            scheme: "HTTPS",
            host: "Example.COM",
            port: 443
        )

        #expect(origin?.scheme == "https")
        #expect(origin?.host == "example.com")
        #expect(origin?.port == nil)
        #expect(origin?.displayName == "https://example.com")
    }

    @Test("Non-default ports remain part of the origin")
    func customPort() {
        let origin = SiteOrigin(url: URL(string: "https://example.com:8443/path"))

        #expect(origin?.port == 8443)
        #expect(origin?.displayName == "https://example.com:8443")
    }

    @Test("Persistent sensitive permission requires HTTPS")
    func persistentPermissionSecurity() {
        #expect(
            SiteOrigin(url: URL(string: "https://example.com"))?
                .allowsPersistentSensitivePermission == true
        )
        #expect(
            SiteOrigin(url: URL(string: "http://localhost:8765"))?
                .allowsPersistentSensitivePermission == false
        )
    }
}
