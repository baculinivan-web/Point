import Foundation

public enum NavigationSchemeDisposition: Equatable, Sendable {
    case allowInWebView
    case confirmExternalApplication
    case block
}

public struct NavigationSchemePolicy: Sendable {
    public init() {}

    public func disposition(for url: URL) -> NavigationSchemeDisposition {
        guard let scheme = url.scheme?.lowercased() else { return .block }
        switch scheme {
        case "http", "https", "about", "blob":
            return .allowInWebView
        case "javascript", "data", "file":
            return .block
        default:
            // OAuth and sign-in flows commonly return to their originating app
            // through a custom URL scheme (for example, `my-app://callback`).
            // WebKit cannot handle those URLs, so offer them to Launch Services
            // while retaining an explicit confirmation at the engine boundary.
            return .confirmExternalApplication
        }
    }
}
