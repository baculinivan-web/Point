import BrowserCore
import BrowserPersistence
import Foundation
import Testing
@testable import BrowserUI

@Suite("Omnibox history privacy")
@MainActor
struct OmniboxHistoryTests {
    @Test func submittedQuerySurvivesRepositoryRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "history.json")
        let model = makeModel(repository: FileBrowsingHistoryRepository(fileURL: file))
        // Recording the query happens at submission, before the page can redirect.
        model.newTab()
        model.omniboxText = "как приготовить рис"
        model.submitOmnibox()
        await model.refreshOmniboxHistory()

        let restored = makeModel(repository: FileBrowsingHistoryRepository(fileURL: file))
        restored.newTab()
        restored.omniboxText = "как при"
        await restored.refreshOmniboxHistory()
        #expect(restored.omniboxSuggestions.contains { $0.kind == .search("как приготовить рис") })
    }

    @Test func historicalDomainQueryActivatesAsSearch() async throws {
        let repository = InMemoryBrowsingHistoryRepository()
        let model = makeModel(repository: repository)
        model.newTab()
        model.activateOmniboxSuggestion(OmniboxSuggestion(
            id: "search:example.com", title: "example.com", detail: "", kind: .search("example.com")
        ))
        await model.refreshOmniboxHistory()
        #expect(model.activeTab?.url?.host == model.searchEngine.searchEndpoint.host)
        #expect(model.omniboxHistory.contains { OmniboxSuggestions.searchQuery(in: $0.url) == "example.com" })
    }

    @Test(arguments: [false, true]) func clearingWaitsForPendingQueryWrite(clearAllData: Bool) async throws {
        let repository = InMemoryBrowsingHistoryRepository()
        let model = makeModel(repository: repository)
        model.newTab()
        model.omniboxText = "pending search"
        model.submitOmnibox()
        if clearAllData {
            model.selectedBrowsingDataCategories = [.history]
            model.clearSelectedBrowsingData()
            while model.isClearingBrowsingData { await Task.yield() }
        } else {
            model.clearBrowsingHistory()
            while model.isLoadingBrowsingHistory { await Task.yield() }
        }
        #expect(try await repository.recent(limit: 10).isEmpty)
        await model.refreshOmniboxHistory()
        #expect(model.omniboxHistory.isEmpty)
    }

    @Test func privateWindowDoesNotReadOrWriteHistory() async throws {
        let repository = InMemoryBrowsingHistoryRepository()
        try await repository.recordVisit(url: URL(string: "https://www.google.com/search?q=secret")!, title: "Secret", visitedAt: Date())
        let model = makeModel(repository: repository, isPrivate: true)
        model.newTab()
        await model.refreshOmniboxHistory()
        #expect(model.omniboxHistory.isEmpty)
        model.omniboxText = "private search"
        model.submitOmnibox()
        await model.refreshOmniboxHistory()
        #expect(try await repository.recent(limit: 10).count == 1)
    }

    @Test func refreshDuringClearCannotRestoreDeletedSuggestions() async throws {
        let repository = DelayedHistoryRepository()
        let model = makeModel(repository: repository)
        model.newTab()
        await model.refreshOmniboxHistory()
        #expect(!model.omniboxHistory.isEmpty)
        model.clearBrowsingHistory()
        await repository.waitForRemoval()
        await model.refreshOmniboxHistory()
        #expect(model.omniboxHistory.isEmpty)
        await repository.completeRemoval()
        while model.isLoadingBrowsingHistory { await Task.yield() }
        await model.refreshOmniboxHistory()
        #expect(model.omniboxHistory.isEmpty)
    }

    private func makeModel(repository: any BrowsingHistoryRepository, isPrivate: Bool = false) -> BrowserWindowModel {
        BrowserWindowModel(
            repository: InMemorySessionRepository(),
            sitePermissionRepository: InMemorySitePermissionRepository(),
            browsingHistoryRepository: repository,
            isPrivate: isPrivate
        )
    }
}

private actor DelayedHistoryRepository: BrowsingHistoryRepository {
    private var entries = [BrowsingHistoryEntry(url: URL(string: "https://example.com")!, title: "Visited")]
    private var removalStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var removalWaiter: CheckedContinuation<Void, Never>?

    func recent(limit: Int) async throws -> [BrowsingHistoryEntry] { Array(entries.prefix(limit)) }
    func recordVisit(url: URL, title: String, visitedAt: Date) async throws -> BrowsingHistoryEntry {
        let entry = BrowsingHistoryEntry(url: url, title: title, visitedAt: visitedAt)
        entries.insert(entry, at: 0)
        return entry
    }
    func updateTitle(_ title: String, for id: UUID) async throws {}
    func removeVisits(before date: Date) async throws {}
    func removeAll() async throws {
        removalStarted = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { removalWaiter = $0 }
        entries = []
    }
    func waitForRemoval() async {
        if removalStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func completeRemoval() { removalWaiter?.resume(); removalWaiter = nil }
}
