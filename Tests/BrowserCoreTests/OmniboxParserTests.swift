import BrowserCore
import Foundation
import Testing

@Suite("Omnibox parser")
struct OmniboxParserTests {
    private let parser = OmniboxParser()

    @Test("Explicit HTTPS stays a URL")
    func explicitHTTPS() {
        #expect(parser.destination(for: "https://example.com/path") == .url(URL(string: "https://example.com/path")!))
    }

    @Test("Domain gets HTTPS")
    func domain() {
        #expect(parser.destination(for: "example.com") == .url(URL(string: "https://example.com")!))
    }

    @Test("Domain address with path and query stays a URL")
    func domainAddress() {
        #expect(
            parser.destination(for: "example.com/path?query=value#section")
                == .url(URL(string: "https://example.com/path?query=value#section")!)
        )
        #expect(
            parser.destination(for: "example.com:8080/path")
                == .url(URL(string: "https://example.com:8080/path")!)
        )
    }

    @Test("Local development hosts are URLs")
    func localHosts() {
        #expect(parser.destination(for: "localhost:8080") == .url(URL(string: "https://localhost:8080")!))
        #expect(parser.destination(for: "127.0.0.1:3000") == .url(URL(string: "https://127.0.0.1:3000")!))
        #expect(parser.destination(for: "[::1]:3000") == .url(URL(string: "https://[::1]:3000")!))
    }

    @Test("Whitespace input becomes a search")
    func search() {
        guard case let .search(url) = parser.destination(for: "  native   mac browser ") else {
            Issue.record("Expected search destination")
            return
        }
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "native mac browser")
    }

    @Test("Every supported search engine builds its own query URL")
    func searchEngines() {
        for searchEngine in SearchEngine.allCases {
            let parser = OmniboxParser(searchEngine: searchEngine)
            guard case let .search(url) = parser.destination(for: "browser test") else {
                Issue.record("Expected search destination for \(searchEngine.displayName)")
                continue
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            #expect(components?.host == searchEngine.searchEndpoint.host)
            #expect(components?.queryItems?.first(where: {
                $0.name == searchEngine.queryParameter
            })?.value == "browser test")
            for fixedItem in searchEngine.fixedQueryItems {
                #expect(components?.queryItems?.contains(fixedItem) == true)
            }
        }
    }

    @Test("ChatGPT starts a new chat with Search enabled")
    func chatGPTSearch() {
        let parser = OmniboxParser(searchEngine: .chatGPT)
        guard case let .search(url) = parser.destination(for: "browser test") else {
            Issue.record("Expected ChatGPT search destination")
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(components?.host == "chatgpt.com")
        #expect(components?.queryItems?.contains(
            URLQueryItem(name: "hints", value: "search")
        ) == true)
        #expect(components?.queryItems?.contains(
            URLQueryItem(name: "q", value: "browser test")
        ) == true)
    }

    @Test("Multiline pasted input is normalized as a search")
    func multilineSearch() {
        guard case let .search(url) = parser.destination(for: "https://example.com\njavascript:alert(1)") else {
            Issue.record("Expected multiline input to be searched safely")
            return
        }
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "https://example.com javascript:alert(1)")
    }

    @Test("Unknown schemes and userinfo are blocked")
    func unsafeInput() {
        guard case .blocked = parser.destination(for: "javascript:alert(1)") else {
            Issue.record("Expected javascript scheme to be blocked")
            return
        }
        guard case .blocked = parser.destination(for: "https://user:secret@example.com") else {
            Issue.record("Expected userinfo to be blocked")
            return
        }
    }

    @Test("Blank input does nothing")
    func empty() {
        #expect(parser.destination(for: " \n \t ") == .empty)
    }
}
