import BrowserCore
import Foundation
import Testing

@Suite("Local omnibox suggestions")
struct OmniboxSuggestionsTests {
    @Test func sitesHaveEnglishAndRussianAliases() {
        for prefix in ["YouTu", "ютуб", "  YOUTUBE  "] {
            let suggestions = OmniboxSuggestions.make(query: prefix)
            #expect(suggestions.first?.kind == .site(URL(string: "https://youtube.com/")!))
        }
        #expect(OmniboxSuggestions.make(query: "youtube download tutorial").isEmpty)
    }

    @Test func mergesSourcesAndDeduplicatesSearchesAndURLs() {
        let url = URL(string: "https://youtube.com/")!
        let tab = OmniboxSuggestion(id: "tab", title: "YouTube", detail: url.absoluteString, kind: .tab(TabID()))
        let history = [
            BrowsingHistoryEntry(url: URL(string: "https://www.google.com/search?q=youtube+music")!, title: "Results"),
            BrowsingHistoryEntry(url: URL(string: "https://yandex.ru/search/?text=YouTube%20music")!, title: "Results"),
            BrowsingHistoryEntry(url: url, title: "YouTube"),
            BrowsingHistoryEntry(url: URL(string: "https://example.com/video")!, title: "YouTube videos")
        ]
        let result = OmniboxSuggestions.make(query: "youtube", tabs: [tab], history: history)
        #expect(result.map(\.id) == ["tab", "search:youtube music", "page:https://example.com/video"])
    }

    @Test func extractsEveryEngineQueryButNotUnrelatedURLs() {
        for engine in SearchEngine.allCases {
            guard case let .search(url) = OmniboxParser(searchEngine: engine).destination(for: "как приготовить рис") else {
                Issue.record("Expected a search URL")
                continue
            }
            #expect(OmniboxSuggestions.searchQuery(in: url) == "как приготовить рис")
        }
        #expect(OmniboxSuggestions.searchQuery(in: URL(string: "https://example.com/?q=private")!) == nil)
        #expect(OmniboxSuggestions.searchQuery(in: URL(string: "https://www.google.com/maps?q=coffee")!) == nil)
    }

    @Test func emptyInputShowsRecentActivityAndKeepsBoundedMixedSources() {
        let tabs = (0..<12).map {
            OmniboxSuggestion(id: "tab\($0)", title: "Tab", detail: "https://tab\($0).example", kind: .tab(TabID()))
        }
        let history = [BrowsingHistoryEntry(url: URL(string: "https://example.com/")!, title: "Visited")]
        let result = OmniboxSuggestions.make(query: "", tabs: tabs, history: history)
        #expect(result.count == 4)
        #expect(result.last?.title == "Visited")
        #expect(OmniboxSuggestions.make(query: "", history: history, limit: 0).isEmpty)
    }

    @Test func largeHistoryRemainsBoundedAndFindsOlderMatches() {
        var history = (0..<5_000).map {
            BrowsingHistoryEntry(url: URL(string: "https://example.com/page/\($0)")!, title: "Page \($0)")
        }
        history.append(BrowsingHistoryEntry(url: URL(string: "https://example.com/older")!, title: "Unique older title"))
        let index = OmniboxHistoryIndex(history)
        let start = ContinuousClock.now
        let result = OmniboxSuggestions.make(query: "unique older", index: index)
        print("Omnibox 5001-row lookup: \(start.duration(to: .now))")
        #expect(result.count == 1)
        #expect(result.first?.title == "Unique older title")
    }

    @Test func arrowsWrapAndRecoverWhenResultsChange() {
        let items = ["first", "second"].map {
            OmniboxSuggestion(id: $0, title: $0, detail: "", kind: .search($0))
        }
        #expect(OmniboxSuggestions.highlightedID(in: items, current: nil, offset: 1) == "first")
        #expect(OmniboxSuggestions.highlightedID(in: items, current: nil, offset: -1) == "second")
        #expect(OmniboxSuggestions.highlightedID(in: items, current: "second", offset: 1) == "first")
        #expect(OmniboxSuggestions.highlightedID(in: items, current: "first", offset: -1) == "second")
        #expect(OmniboxSuggestions.highlightedID(in: items, current: "removed", offset: 1) == "first")
        #expect(OmniboxSuggestions.highlightedID(in: [], current: "first", offset: 1) == nil)
    }
}
