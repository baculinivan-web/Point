import BrowserCore
import Foundation
import Testing

@Suite("Persisted tab navigation history")
struct TabNavigationHistoryTests {
    @Test("AppKit horizontal swipe deltas map to browser direction")
    func swipeDirection() {
        #expect(NavigationSwipeDirection(deltaX: -1, deltaY: 0) == .back)
        #expect(NavigationSwipeDirection(deltaX: 1, deltaY: 0) == .forward)
        #expect(NavigationSwipeDirection(deltaX: 0, deltaY: 1) == nil)
    }

    @Test("New navigation truncates the forward branch")
    func truncatesForwardBranch() {
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!
        let replacement = URL(string: "https://example.com/replacement")!
        var history = TabNavigationHistory(url: first, title: "First")
        history.recordNavigation(url: second, title: "Second")
        _ = history.move(to: 0, committedURL: first, title: "First")

        history.recordNavigation(url: replacement, title: "Replacement")

        #expect(history.entries.map(\.url) == [first, replacement])
        #expect(history.currentIndex == 1)
        #expect(history.forwardIndex == nil)
    }

    @Test("Back and forward indexes survive a Codable round-trip")
    func codableRoundTrip() throws {
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!
        let third = URL(string: "https://example.com/third")!
        var history = TabNavigationHistory(url: first, title: "First")
        history.recordNavigation(url: second, title: "Second")
        history.recordNavigation(url: third, title: "Third")
        _ = history.move(to: 1, committedURL: second, title: "Second")

        let restored = try JSONDecoder().decode(
            TabNavigationHistory.self,
            from: JSONEncoder().encode(history)
        )

        #expect(restored == history)
        #expect(restored.backIndex == 0)
        #expect(restored.forwardIndex == 2)
    }

    @Test("History keeps a bounded recent stack")
    func boundedStack() {
        var history = TabNavigationHistory()
        for index in 0..<75 {
            history.recordNavigation(
                url: URL(string: "https://example.com/\(index)")!,
                title: "Page \(index)"
            )
        }

        #expect(history.entries.count == 50)
        #expect(history.entries.first?.url.path == "/25")
        #expect(history.currentEntry?.url.path == "/74")
    }

    @Test("Corrupted persisted index is clamped safely")
    func clampsCorruptedIndex() throws {
        let data = Data(
            """
            {"entries":[{"url":"https://example.com","title":"Example"}],"currentIndex":999}
            """.utf8
        )
        let history = try JSONDecoder().decode(TabNavigationHistory.self, from: data)

        #expect(history.currentIndex == 0)
        #expect(history.currentEntry?.url.host == "example.com")
    }
}
