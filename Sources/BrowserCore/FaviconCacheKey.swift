import Foundation

public enum FaviconCacheKey {
    public static func make(for pageURL: URL) -> String? {
        guard let scheme = pageURL.scheme?.lowercased(),
              let host = pageURL.host?.lowercased()
        else { return nil }
        let origin = "\(scheme)://\(host):\(pageURL.port ?? defaultPort(for: scheme))"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in origin.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16, uppercase: false)
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }
}
