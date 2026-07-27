import Foundation

public struct TabID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TabFolderID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum SidebarMode: String, Codable, Sendable, CaseIterable {
    case pinned
    case autoHide
}

public enum NavigationSwipeDirection: Sendable, Equatable {
    case back
    case forward

    public init?(deltaX: Double, deltaY: Double) {
        guard abs(deltaX) > abs(deltaY), deltaX != 0 else { return nil }
        self = deltaX < 0 ? .back : .forward
    }
}

public enum TabLifecycleState: String, Codable, Sendable {
    case active
    case liveBackground
    case suspended
    case evicted
    case restoring
    case crashed
}

public struct TabNavigationEntry: Codable, Equatable, Sendable {
    public var url: URL
    public var title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

public struct TabNavigationHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [TabNavigationEntry]
    public private(set) var currentIndex: Int

    public init(entries: [TabNavigationEntry] = [], currentIndex: Int = 0) {
        self.entries = entries
        self.currentIndex = entries.isEmpty
            ? 0
            : min(max(currentIndex, 0), entries.count - 1)
    }

    public init(url: URL?, title: String) {
        if let url {
            entries = [TabNavigationEntry(url: url, title: title)]
        } else {
            entries = []
        }
        currentIndex = 0
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case currentIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entries: try container.decode([TabNavigationEntry].self, forKey: .entries),
            currentIndex: try container.decode(Int.self, forKey: .currentIndex)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(currentIndex, forKey: .currentIndex)
    }

    public var currentEntry: TabNavigationEntry? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    public var backIndex: Int? {
        currentIndex > 0 ? currentIndex - 1 : nil
    }

    public var forwardIndex: Int? {
        currentIndex + 1 < entries.count ? currentIndex + 1 : nil
    }

    public mutating func recordNavigation(
        url: URL,
        title: String,
        limit: Int = 50
    ) {
        if entries.indices.contains(currentIndex), entries[currentIndex].url == url {
            entries[currentIndex].title = title
            return
        }
        if entries.indices.contains(currentIndex), currentIndex + 1 < entries.count {
            entries.removeSubrange((currentIndex + 1)..<entries.count)
        }
        entries.append(TabNavigationEntry(url: url, title: title))
        currentIndex = entries.count - 1

        let overflow = max(0, entries.count - max(1, limit))
        if overflow > 0 {
            entries.removeFirst(overflow)
            currentIndex -= overflow
        }
    }

    public mutating func updateCurrentTitle(_ title: String) {
        guard entries.indices.contains(currentIndex) else { return }
        entries[currentIndex].title = title
    }

    @discardableResult
    public mutating func move(
        to index: Int,
        committedURL: URL,
        title: String
    ) -> Bool {
        guard entries.indices.contains(index) else { return false }
        currentIndex = index
        entries[index] = TabNavigationEntry(url: committedURL, title: title)
        return true
    }
}

public struct PersistedTab: Codable, Equatable, Identifiable, Sendable {
    public let id: TabID
    public var title: String
    public var url: URL?
    public var faviconURL: URL?
    public var isPinned: Bool
    public var folderID: TabFolderID?
    public var position: Int64
    public var navigationHistory: TabNavigationHistory?
    /// True when the tab was opened by the AI assistant.
    public var isAICreated: Bool

    public init(
        id: TabID,
        title: String,
        url: URL?,
        faviconURL: URL? = nil,
        isPinned: Bool,
        folderID: TabFolderID? = nil,
        position: Int64,
        navigationHistory: TabNavigationHistory? = nil,
        isAICreated: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.faviconURL = faviconURL
        self.isPinned = isPinned
        self.folderID = folderID
        self.position = position
        self.navigationHistory = navigationHistory
        self.isAICreated = isAICreated
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case faviconURL
        case isPinned
        case folderID
        case position
        case navigationHistory
        case isAICreated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        faviconURL = try container.decodeIfPresent(URL.self, forKey: .faviconURL)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        folderID = try container.decodeIfPresent(TabFolderID.self, forKey: .folderID)
        position = try container.decode(Int64.self, forKey: .position)
        navigationHistory = try container.decodeIfPresent(
            TabNavigationHistory.self,
            forKey: .navigationHistory
        )
        isAICreated = try container.decodeIfPresent(Bool.self, forKey: .isAICreated) ?? false
    }
}

public struct PersistedTabFolder: Codable, Equatable, Identifiable, Sendable {
    public let id: TabFolderID
    public var name: String
    public var symbolName: String?
    public var parentID: TabFolderID?
    public var position: Int64
    public var isExpanded: Bool
    /// A two-pane workspace. Its children are the left and right tabs, in order.
    public var isSplit: Bool
    /// The fraction of the workspace occupied by the left pane.
    public var splitRatio: Double?

    public init(
        id: TabFolderID = TabFolderID(),
        name: String,
        symbolName: String? = "folder.fill",
        parentID: TabFolderID? = nil,
        position: Int64,
        isExpanded: Bool = true,
        isSplit: Bool = false,
        splitRatio: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.parentID = parentID
        self.position = position
        self.isExpanded = isExpanded
        self.isSplit = isSplit
        self.splitRatio = splitRatio
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case symbolName
        case parentID
        case position
        case isExpanded
        case isSplit
        case splitRatio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabFolderID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)
        parentID = try container.decodeIfPresent(TabFolderID.self, forKey: .parentID)
        position = try container.decode(Int64.self, forKey: .position)
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        isSplit = try container.decodeIfPresent(Bool.self, forKey: .isSplit) ?? false
        splitRatio = try container.decodeIfPresent(Double.self, forKey: .splitRatio)
    }
}

public struct BrowserSessionSnapshot: Codable, Equatable, Sendable {
    public var selectedTabID: TabID?
    public var sidebarMode: SidebarMode
    public var tabs: [PersistedTab]
    public var folders: [PersistedTabFolder]

    public init(
        selectedTabID: TabID?,
        sidebarMode: SidebarMode,
        tabs: [PersistedTab],
        folders: [PersistedTabFolder] = []
    ) {
        self.selectedTabID = selectedTabID
        self.sidebarMode = sidebarMode
        self.tabs = tabs
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey {
        case selectedTabID
        case sidebarMode
        case tabs
        case folders
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedTabID = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
        sidebarMode = try container.decode(SidebarMode.self, forKey: .sidebarMode)
        tabs = try container.decode([PersistedTab].self, forKey: .tabs)
        folders = try container.decodeIfPresent(
            [PersistedTabFolder].self,
            forKey: .folders
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
        try container.encode(sidebarMode, forKey: .sidebarMode)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(folders, forKey: .folders)
    }
}

public protocol SessionRepository: Sendable {
    func load() async throws -> BrowserSessionSnapshot?
    func save(_ snapshot: BrowserSessionSnapshot) async throws
}

public enum BrowserCommand: Sendable {
    case newTab(background: Bool)
    case closeTab(TabID)
    case closeAllTabs
    case reopenClosedTab
    case selectTab(TabID)
    case moveTab(TabID, before: TabID?)
    case pinTab(TabID, Bool)
    case load(TabID, OmniboxDestination)
    case goBack(TabID)
    case goForward(TabID)
    case reload(TabID, bypassCache: Bool)
    case stop(TabID)
    case toggleSidebar
    case focusOmnibox
    case findInPage
}
