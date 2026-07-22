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
        case "mailto", "tel", "facetime":
            return .confirmExternalApplication
        default:
            return .block
        }
    }
}
