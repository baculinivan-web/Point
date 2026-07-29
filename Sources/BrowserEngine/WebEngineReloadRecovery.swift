import Foundation

enum WebEngineReloadRecovery {
    static func request(
        currentURL: URL?,
        lastMainFrameRequest: URLRequest?,
        fallbackURL: URL?,
        provisionalNavigationFailed: Bool,
        bypassingCache: Bool
    ) -> URLRequest? {
        guard provisionalNavigationFailed || currentURL == nil else { return nil }

        guard var request = lastMainFrameRequest
            ?? fallbackURL.map({ URLRequest(url: $0) })
        else { return nil }

        if bypassingCache {
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        return request
    }
}
