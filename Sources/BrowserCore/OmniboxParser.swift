import Foundation

public enum OmniboxDestination: Equatable, Sendable {
    case empty
    case url(URL)
    case search(URL)
    case blocked(reason: String)
}

public struct OmniboxParser: Sendable {
    public let searchEndpoint: URL
    public let searchQueryParameter: String
    public let fixedSearchQueryItems: [URLQueryItem]

    public init(
        searchEndpoint: URL = URL(string: "https://duckduckgo.com/")!,
        searchQueryParameter: String = "q",
        fixedSearchQueryItems: [URLQueryItem] = []
    ) {
        self.searchEndpoint = searchEndpoint
        self.searchQueryParameter = searchQueryParameter
        self.fixedSearchQueryItems = fixedSearchQueryItems
    }

    public init(searchEngine: SearchEngine) {
        self.init(
            searchEndpoint: searchEngine.searchEndpoint,
            searchQueryParameter: searchEngine.queryParameter,
            fixedSearchQueryItems: searchEngine.fixedQueryItems
        )
    }

    public func destination(for rawInput: String) -> OmniboxDestination {
        let input = normalize(rawInput)
        guard !input.isEmpty else { return .empty }

        if !input.contains("://"), !input.contains(" "), looksLikeHost(input),
           let components = URLComponents(string: "https://\(input)"),
           components.user == nil,
           components.password == nil,
           let url = components.url {
            return .url(url)
        }

        if input.contains(" ") {
            return searchURL(for: input)
        }

        if let explicit = URLComponents(string: input), let scheme = explicit.scheme {
            guard ["http", "https"].contains(scheme.lowercased()) else {
                return .blocked(reason: "Схема \(scheme) не поддерживается")
            }
            guard explicit.user == nil, explicit.password == nil else {
                return .blocked(reason: "Адреса с логином или паролем заблокированы")
            }
            guard let url = explicit.url, explicit.host != nil else {
                return searchURL(for: input)
            }
            return .url(url)
        }

        return searchURL(for: input)
    }

    private func normalize(_ input: String) -> String {
        input
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func looksLikeHost(_ input: String) -> Bool {
        let candidate = input.lowercased()
        if candidate == "localhost" || candidate.hasPrefix("localhost:") {
            return true
        }

        if candidate.hasPrefix("["), let closingBracket = candidate.firstIndex(of: "]") {
            let suffix = candidate[candidate.index(after: closingBracket)...]
            return suffix.isEmpty || (suffix.first == ":" && suffix.dropFirst().allSatisfy(\.isNumber))
        }

        let host = candidate.split(separator: ":", maxSplits: 1).first.map(String.init) ?? candidate
        if isIPv4(host) {
            return true
        }

        return host.contains(".")
            && !host.hasPrefix(".")
            && !host.hasSuffix(".")
            && host.unicodeScalars.allSatisfy { scalar in
                CharacterSet.letters.contains(scalar)
                    || CharacterSet.decimalDigits.contains(scalar)
                    || scalar == "-"
                    || scalar == "."
            }
    }

    private func isIPv4(_ input: String) -> Bool {
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    private func searchURL(for query: String) -> OmniboxDestination {
        var components = URLComponents(
            url: searchEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = fixedSearchQueryItems + [
            URLQueryItem(name: searchQueryParameter, value: query)
        ]
        guard let url = components?.url else {
            return .blocked(reason: "Не удалось сформировать поисковый запрос")
        }
        return .search(url)
    }
}
