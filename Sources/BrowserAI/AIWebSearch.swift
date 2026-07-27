import Foundation

public struct AIWebSearchResult: Sendable, Equatable {
    public let title: String
    public let url: URL
    public let snippet: String
}

/// Web search backed by the browser's own networking stack: it fetches the
/// DuckDuckGo HTML endpoint with the browser user agent and extracts results
/// without any third-party API key.
public enum AIWebSearch {
    private static let endpoint = URL(string: "https://html.duckduckgo.com/html/")!

    public static func search(query: String, limit: Int = 6) async throws -> [AIWebSearchResult] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else { throw AIProviderError.invalidResponse }
        return parse(html: html, limit: limit)
    }

    /// Extracts `result__a` anchors and `result__snippet` bodies from the
    /// static HTML page. Regex is enough here: the endpoint is a stable,
    /// script-free page designed for exactly this kind of consumption.
    static func parse(html: String, limit: Int) -> [AIWebSearchResult] {
        let anchorPattern = /<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/
            .dotMatchesNewlines()
        let snippetPattern = /class="[^"]*result__snippet[^"]*"[^>]*>(.*?)<\/(?:a|td|div)>/
            .dotMatchesNewlines()

        let anchors = html.matches(of: anchorPattern)
        let snippets = html.matches(of: snippetPattern).map {
            plainText(fromHTML: String($0.output.1))
        }

        var results: [AIWebSearchResult] = []
        for (index, match) in anchors.enumerated() {
            guard results.count < limit else { break }
            guard let url = resolveResultURL(String(match.output.1)) else { continue }
            let title = plainText(fromHTML: String(match.output.2))
            guard !title.isEmpty else { continue }
            let snippet = index < snippets.count ? snippets[index] : ""
            results.append(AIWebSearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// DuckDuckGo wraps result links in a redirect
    /// (`//duckduckgo.com/l/?uddg=<encoded>`); unwrap to the real URL.
    private static func resolveResultURL(_ raw: String) -> URL? {
        let unescaped = raw
            .replacingOccurrences(of: "&amp;", with: "&")
        let absolute = unescaped.hasPrefix("//") ? "https:" + unescaped : unescaped
        guard let url = URL(string: absolute) else { return nil }
        if url.host?.contains("duckduckgo.com") == true,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let targetURL = URL(string: target) {
            return targetURL
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Fetches a URL and reduces it to readable text, for the `read_page`
    /// tool when the page is not already open in a tab.
    public static func fetchPlainText(url: URL, limit: Int = 12000) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw AIProviderError.invalidResponse }
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw AIProviderError.invalidResponse }

        var stripped = html
        for tag in ["script", "style", "noscript", "svg", "head"] {
            stripped = stripped.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let text = plainText(fromHTML: stripped)
            .replacingOccurrences(
                of: "\\s{3,}",
                with: "\n",
                options: .regularExpression
            )
        return String(text.prefix(limit))
    }

    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
