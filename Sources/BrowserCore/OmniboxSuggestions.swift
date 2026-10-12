import Foundation

public struct OmniboxSuggestion: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case tab(TabID)
        case search(String)
        case page(URL)
        case site(URL)
    }

    public let id: String
    public let title: String
    public let detail: String
    public let kind: Kind

    public init(id: String, title: String, detail: String, kind: Kind) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
    }
}

/// Decodes URLs and normalizes searchable text once, rather than on each keystroke.
public struct OmniboxHistoryIndex: Sendable {
    fileprivate struct Record: Sendable {
        let entry: BrowsingHistoryEntry
        let search: String?
        let searchKey: String
        let text: String
    }

    fileprivate let records: [Record]

    public init(_ history: [BrowsingHistoryEntry] = []) {
        records = history.compactMap { entry in
            guard ["http", "https"].contains(entry.url.scheme?.lowercased() ?? "") else { return nil }
            let search = OmniboxSuggestions.searchQuery(in: entry.url)
            return Record(
                entry: entry, search: search,
                searchKey: OmniboxSuggestions.normalized(search ?? ""),
                text: OmniboxSuggestions.normalized(entry.title + " " + entry.url.absoluteString)
            )
        }
    }
}

/// Local suggestions only. No keystrokes or history are sent to a service.
public enum OmniboxSuggestions {
    public static func make(
        query: String,
        tabs: [OmniboxSuggestion] = [],
        history: [BrowsingHistoryEntry] = [],
        limit: Int = 8
    ) -> [OmniboxSuggestion] {
        make(query: query, tabs: tabs, index: OmniboxHistoryIndex(history), limit: limit)
    }

    public static func make(
        query: String,
        tabs: [OmniboxSuggestion] = [],
        index: OmniboxHistoryIndex,
        limit: Int = 8
    ) -> [OmniboxSuggestion] {
        guard limit > 0 else { return [] }
        let query = normalized(query)
        var result = Array(tabs.filter { query.isEmpty || matches($0.title + " " + $0.detail, query: query) }.prefix(3))
        var seenURLs = Set(result.compactMap { suggestion -> String? in
            guard case .tab = suggestion.kind else { return nil }
            return suggestion.detail
        })
        var seenQueries = Set<String>()
        var searches: [OmniboxSuggestion] = []
        var pages: [OmniboxSuggestion] = []
        let words = query.split(separator: " ")
        for record in index.records {
            let entry = record.entry
            if let search = record.search {
                let key = record.searchKey
                if (query.isEmpty || key.hasPrefix(query)), seenQueries.insert(key).inserted {
                    searches.append(OmniboxSuggestion(
                        id: "search:" + key, title: search, detail: "", kind: .search(search)
                    ))
                }
                continue
            }
            let url = entry.url.absoluteString
            guard query.isEmpty || words.allSatisfy({ record.text.contains($0) }),
                  seenURLs.insert(url).inserted else { continue }
            pages.append(OmniboxSuggestion(
                id: "page:" + url,
                title: entry.title.isEmpty ? (entry.url.host ?? url) : entry.title,
                detail: url, kind: .page(entry.url)
            ))
        }
        // Reserve room for both remembered queries and visited pages.
        result += searches.prefix(3)
        if !query.isEmpty {
            for site in sites where site.aliases.contains(where: { normalized($0).hasPrefix(query) }) {
                let url = URL(string: "https://" + site.host + "/")!
                guard seenURLs.insert(url.absoluteString).inserted else { continue }
                result.append(OmniboxSuggestion(
                    id: "site:" + site.host, title: site.name,
                    detail: site.host, kind: .site(url)
                ))
                if result.count >= limit { break }
            }
        }
        result += pages
        result += searches.dropFirst(3)
        return Array(result.prefix(limit))
    }

    public static func highlightedID(
        in suggestions: [OmniboxSuggestion], current: String?, offset: Int
    ) -> String? {
        guard !suggestions.isEmpty else { return nil }
        guard let current, let index = suggestions.firstIndex(where: { $0.id == current }) else {
            return offset > 0 ? suggestions.first?.id : suggestions.last?.id
        }
        let count = suggestions.count
        return suggestions[((index + offset) % count + count) % count].id
    }

    public static func searchQuery(in url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Search pages also use form encoding, where a literal + means a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let host = components.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        guard let engine = SearchEngine.allCases.first(where: {
            let endpointHost = $0.searchEndpoint.host?.lowercased().replacingOccurrences(of: "www.", with: "")
            return endpointHost == host && $0.searchEndpoint.path == url.path
        }), let query = components.queryItems?.first(where: { $0.name == engine.queryParameter })?.value else {
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matches(_ text: String, query: String) -> Bool {
        let text = normalized(text)
        return query.split(separator: " ").allSatisfy { text.contains($0) }
    }

    fileprivate static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let sites: [(name: String, host: String, aliases: [String])] = [
        ("YouTube", "youtube.com", ["youtube", "ютуб", "ютюб"]),
        ("Google", "google.com", ["google", "гугл"]),
        ("Яндекс", "yandex.ru", ["yandex", "яндекс"]),
        ("Wikipedia", "wikipedia.org", ["wikipedia", "википедия"]),
        ("GitHub", "github.com", ["github", "гитхаб"]),
        ("Reddit", "reddit.com", ["reddit", "реддит"]),
        ("Telegram", "web.telegram.org", ["telegram", "телеграм"]),
        ("VK", "vk.com", ["vk", "вк", "вконтакте"]),
        ("Twitch", "twitch.tv", ["twitch", "твич"]),
        ("ChatGPT", "chatgpt.com", ["chatgpt", "чатгпт"]),
        ("Gmail", "mail.google.com", ["gmail", "джимейл"]),
        ("Ozon", "ozon.ru", ["ozon", "озон"]),
        ("Wildberries", "wildberries.ru", ["wildberries", "вайлдберриз"])
    ]
}
