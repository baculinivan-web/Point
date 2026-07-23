import BrowserCore
import BrowserPersistence
import Foundation
import Testing

@Suite("Session persistence")
struct FileSessionRepositoryTests {
    @Test("Session round-trips without losing tab order")
    func roundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BrowserTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileSessionRepository(
            fileURL: directory.appending(path: "session.json")
        )
        let firstID = TabID()
        let secondID = TabID()
        let workFolderID = TabFolderID()
        let researchFolderID = TabFolderID()
        let snapshot = BrowserSessionSnapshot(
            selectedTabID: secondID,
            sidebarMode: .autoHide,
            tabs: [
                PersistedTab(
                    id: firstID,
                    title: "First",
                    url: URL(string: "https://example.com"),
                    faviconURL: URL(string: "https://cdn.example.com/icon.png"),
                    isPinned: true,
                    position: 1024,
                    navigationHistory: TabNavigationHistory(
                        entries: [
                            TabNavigationEntry(
                                url: URL(string: "https://example.com/previous")!,
                                title: "Previous"
                            ),
                            TabNavigationEntry(
                                url: URL(string: "https://example.com")!,
                                title: "First"
                            )
                        ],
                        currentIndex: 1
                    )
                ),
                PersistedTab(
                    id: secondID,
                    title: "Second",
                    url: URL(string: "https://example.org"),
                    isPinned: false,
                    folderID: researchFolderID,
                    position: 2048
                )
            ],
            folders: [
                PersistedTabFolder(
                    id: workFolderID,
                    name: "Работа",
                    symbolName: "briefcase.fill",
                    position: 1024
                ),
                PersistedTabFolder(
                    id: researchFolderID,
                    name: "Исследование",
                    parentID: workFolderID,
                    position: 1024,
                    isExpanded: false
                )
            ]
        )

        try await repository.save(snapshot)
        let restored = try await repository.load()

        #expect(restored == snapshot)
    }

    @Test("A missing session is a clean first launch")
    func missingSession() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "BrowserMissing-\(UUID().uuidString).json")
        let repository = FileSessionRepository(fileURL: fileURL)
        #expect(try await repository.load() == nil)
    }

    @Test("Sessions from before tab folders decode with an empty tree")
    func legacySessionWithoutFolders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BrowserLegacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "session.json")
        let tabID = UUID()
        let json = """
        {
          "selectedTabID" : { "rawValue" : "\(tabID.uuidString)" },
          "sidebarMode" : "pinned",
          "tabs" : [
            {
              "id" : { "rawValue" : "\(tabID.uuidString)" },
              "title" : "Legacy",
              "url" : "https://example.com",
              "isPinned" : false,
              "position" : 1024
            }
          ]
        }
        """
        try Data(json.utf8).write(to: fileURL)

        let restored = try await FileSessionRepository(fileURL: fileURL).load()
        #expect(restored?.folders == [])
        #expect(restored?.tabs.first?.folderID == nil)
    }
}

@Suite("Site permission persistence")
struct FileSitePermissionRepositoryTests {
    @Test("Decisions round-trip and remain isolated by origin and kind")
    func roundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BrowserPermissionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "permissions.json")
        let repository = FileSitePermissionRepository(fileURL: fileURL)
        let origin = SiteOrigin(url: URL(string: "https://example.com"))!
        let otherOrigin = SiteOrigin(url: URL(string: "https://example.org"))!

        #expect(try await repository.decision(for: origin, kind: .camera) == nil)
        try await repository.save(.allow, for: origin, kind: .camera)

        let restored = FileSitePermissionRepository(fileURL: fileURL)
        #expect(try await restored.decision(for: origin, kind: .camera) == .allow)
        #expect(try await restored.decision(for: origin, kind: .microphone) == nil)
        #expect(try await restored.decision(for: otherOrigin, kind: .camera) == nil)
        #expect(try await restored.permissions().count == 1)

        try await restored.save(.deny, for: origin, kind: .camera)
        #expect(try await restored.decision(for: origin, kind: .camera) == .deny)

        try await restored.remove(for: origin, kind: .camera)
        #expect(try await restored.permissions().isEmpty)

        try await restored.save(.deny, for: origin, kind: .microphone)
        try await restored.save(.allow, for: otherOrigin, kind: .camera)
        try await restored.removeAll()
        #expect(try await restored.permissions().isEmpty)
    }
}

@Suite("Download history persistence")
struct FileDownloadHistoryRepositoryTests {
    @Test("History round-trips without source URL or resume data fields")
    func privateRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BrowserDownloadTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "downloads.json")
        let repository = FileDownloadHistoryRepository(fileURL: fileURL)
        let records = [
            DownloadHistoryRecord(
                id: UUID(),
                suggestedFilename: "report.pdf",
                destinationURL: URL(filePath: "/Users/test/Downloads/report.pdf"),
                state: .finished,
                completedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            DownloadHistoryRecord(
                id: UUID(),
                suggestedFilename: "archive.zip",
                destinationURL: nil,
                state: .failed,
                completedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ]

        try await repository.save(records)
        #expect(try await repository.load() == records)

        let encoded = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!encoded.contains("sourceURL"))
        #expect(!encoded.contains("resumeData"))
        #expect(!encoded.contains("secret="))
    }

    @Test("Missing history starts empty")
    func missingHistory() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "BrowserDownloadsMissing-\(UUID().uuidString).json")
        let repository = FileDownloadHistoryRepository(fileURL: fileURL)
        #expect(try await repository.load().isEmpty)
    }
}

@Suite("Browsing history persistence")
struct FileBrowsingHistoryRepositoryTests {
    @Test("Visits persist newest first and finished title can be updated")
    func roundTripAndTitleUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BrowserHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "history.json")
        let repository = FileBrowsingHistoryRepository(fileURL: fileURL)
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "https://example.org/second")!
        let first = try await repository.recordVisit(
            url: firstURL,
            title: "Loading",
            visitedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = try await repository.recordVisit(
            url: secondURL,
            title: "Second",
            visitedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try await repository.updateTitle("Finished", for: first.id)

        let restored = FileBrowsingHistoryRepository(fileURL: fileURL)
        let entries = try await restored.recent(limit: 10)
        #expect(entries.map(\.url) == [secondURL, firstURL])
        #expect(entries.last?.title == "Finished")
    }

    @Test("Rapid duplicate commits merge and retention stays bounded")
    func mergeAndRetention() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BrowserHistoryBoundTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileBrowsingHistoryRepository(
            fileURL: directory.appending(path: "history.json"),
            retentionLimit: 3,
            duplicateMergeInterval: 30
        )
        let duplicateURL = URL(string: "https://example.com")!
        let first = try await repository.recordVisit(
            url: duplicateURL,
            title: "First",
            visitedAt: Date(timeIntervalSince1970: 100)
        )
        let merged = try await repository.recordVisit(
            url: duplicateURL,
            title: "Updated",
            visitedAt: Date(timeIntervalSince1970: 120)
        )
        #expect(merged.id == first.id)
        #expect(try await repository.recent(limit: 10).count == 1)

        for index in 1...3 {
            _ = try await repository.recordVisit(
                url: URL(string: "https://example.org/\(index)")!,
                title: "Page \(index)",
                visitedAt: Date(timeIntervalSince1970: 200 + Double(index))
            )
        }
        let bounded = try await repository.recent(limit: 10)
        #expect(bounded.count == 3)
        #expect(bounded.first?.url.absoluteString == "https://example.org/3")

        try await repository.removeAll()
        #expect(try await repository.recent(limit: 10).isEmpty)
    }
}
