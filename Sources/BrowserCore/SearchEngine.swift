import Foundation

public enum SearchEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case duckDuckGo
    case google
    case bing
    case brave
    case yandex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .yandex: "Яндекс"
        }
    }

    public var searchEndpoint: URL {
        switch self {
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        case .google: URL(string: "https://www.google.com/search")!
        case .bing: URL(string: "https://www.bing.com/search")!
        case .brave: URL(string: "https://search.brave.com/search")!
        case .yandex: URL(string: "https://yandex.ru/search/")!
        }
    }

    public var queryParameter: String {
        self == .yandex ? "text" : "q"
    }

}
