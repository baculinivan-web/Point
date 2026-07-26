import AppKit
import BrowserAI
import BrowserCore
import Foundation
import Observation

/// Hands the chat real browser capabilities: reading the current page,
/// searching, opening and organizing tabs, screenshots, Python, and memory.
@MainActor
final class BrowserAIToolBridge: AIChatToolExecutor {
    private weak var model: BrowserWindowModel?
    private let memories: AIMemoryStore

    init(model: BrowserWindowModel, memories: AIMemoryStore = .shared) {
        self.model = model
        self.memories = memories
    }

    var toolSpecs: [AIToolSpec] {
        [
            spec(
                "web_search",
                "Search the web. Returns titles, URLs, and snippets of the top results.",
                properties: [
                    "query": string("The search query.")
                ],
                required: ["query"]
            ),
            spec(
                "open_tab",
                "Open a URL in a new browser tab for the person. Set background=false "
                    + "only when they want to switch to it.",
                properties: [
                    "url": string("Absolute http(s) URL to open."),
                    "background": boolean("Open without switching to the tab. Default true.")
                ],
                required: ["url"]
            ),
            spec(
                "read_page",
                "Fetch a URL and return its readable text without opening a visible tab.",
                properties: [
                    "url": string("Absolute http(s) URL to read.")
                ],
                required: ["url"]
            ),
            spec(
                "screenshot_page",
                "Capture a screenshot of a page and look at it. Use for layout, charts, "
                    + "or anything the text does not convey. Defaults to the current page.",
                properties: [
                    "url": string("Optional URL of an open tab; omit for the current page.")
                ],
                required: []
            ),
            spec(
                "run_python",
                "Run a short Python 3 script and return its output. No network access; "
                    + "print results to stdout.",
                properties: [
                    "code": string("The Python source to run.")
                ],
                required: ["code"]
            ),
            spec(
                "list_tabs",
                "List the tabs open in this window with their ids, titles, and URLs.",
                properties: [:],
                required: []
            ),
            spec(
                "group_tabs",
                "Move tabs into a named folder in the sidebar to organize them. "
                    + "Pick an icon that suits the folder's contents.",
                properties: [
                    "name": string("Folder name."),
                    "tab_ids": array(
                        "Tab ids from list_tabs to move into the folder.",
                        itemDescription: "A tab id."
                    ),
                    "icon": stringEnum(
                        "SF Symbol for the folder. Defaults to a plain folder.",
                        values: Self.folderSymbolNames
                    )
                ],
                required: ["name", "tab_ids"]
            ),
            spec(
                "remember",
                "Save a durable note for future conversations. Use for preferences, "
                    + "ongoing projects, and stable facts. Never store secrets.",
                properties: [
                    "text": string("The fact to remember, in one or two sentences.")
                ],
                required: ["text"]
            ),
            spec(
                "recall_memories",
                "List the most recent things you remember about this person.",
                properties: [
                    "limit": number("How many to return. Default 20.")
                ],
                required: []
            ),
            spec(
                "search_memories",
                "Search remembered notes by keyword.",
                properties: [
                    "query": string("Words to search for.")
                ],
                required: ["query"]
            ),
            spec(
                "forget_memory",
                "Delete a remembered note by the id shown next to it.",
                properties: [
                    "id": string("The memory id.")
                ],
                required: ["id"]
            )
        ]
    }

    func currentPageContext() async -> AIPageContext? {
        guard let tab = model?.activeTab, let url = tab.url else { return nil }
        let title = tab.displayTitle
        let text = await tab.engine?.extractPageText(limit: 12000) ?? ""
        return AIPageContext(url: url, title: title, text: text)
    }

    func executeTool(name: String, arguments: AIJSONValue) async throws -> AIToolOutput {
        switch name {
        case "web_search": try await runWebSearch(arguments)
        case "open_tab": try await runOpenTab(arguments)
        case "read_page": try await runReadPage(arguments)
        case "screenshot_page": try await runScreenshot(arguments)
        case "run_python": try await runPython(arguments)
        case "list_tabs": runListTabs()
        case "group_tabs": try runGroupTabs(arguments)
        case "remember": try runRemember(arguments)
        case "recall_memories": runRecallMemories(arguments)
        case "search_memories": try runSearchMemories(arguments)
        case "forget_memory": try runForgetMemory(arguments)
        default: throw AIToolBridgeError.unknownTool(name)
        }
    }

    // MARK: - Web

    private func runWebSearch(_ arguments: AIJSONValue) async throws -> AIToolOutput {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw AIToolBridgeError.invalidArguments
        }
        let results = try await AIWebSearch.search(query: query)
        guard !results.isEmpty else { return AIToolOutput(text: "No results found.") }
        let text = results.enumerated().map { index, result in
            """
            \(index + 1). \(result.title)
            \(result.url.absoluteString)
            \(result.snippet)
            """
        }.joined(separator: "\n\n")
        return AIToolOutput(text: text)
    }

    private func runOpenTab(_ arguments: AIJSONValue) async throws -> AIToolOutput {
        let url = try Self.webURL(from: arguments["url"]?.stringValue)
        let inBackground = arguments["background"]?.boolValue ?? true
        guard let model else { throw AIToolBridgeError.windowClosed }
        model.openAssistantTab(url: url, inBackground: inBackground)
        return AIToolOutput(
            text: "Opened \(url.absoluteString) in a "
                + "\(inBackground ? "background" : "foreground") tab."
        )
    }

    private func runReadPage(_ arguments: AIJSONValue) async throws -> AIToolOutput {
        let url = try Self.webURL(from: arguments["url"]?.stringValue)
        // Prefer the live tab when the page is already loaded: it reflects the
        // rendered DOM, including client-side content a plain fetch would miss.
        if let tab = model?.tabs.first(where: { $0.url == url }),
           let engine = tab.engine,
           let text = await engine.extractPageText(limit: 12000),
           !text.isEmpty {
            return AIToolOutput(text: text)
        }
        return AIToolOutput(text: try await AIWebSearch.fetchPlainText(url: url))
    }

    private func runScreenshot(_ arguments: AIJSONValue) async throws -> AIToolOutput {
        guard AIChatSettings.shared.supportsImageAttachments else {
            return AIToolOutput(
                text: "The selected model cannot look at images, so a screenshot "
                    + "would not help. Use read_page instead."
            )
        }
        guard let model else { throw AIToolBridgeError.windowClosed }

        let tab: BrowserTab?
        if let raw = arguments["url"]?.stringValue, !raw.isEmpty {
            let url = try Self.webURL(from: raw)
            tab = model.tabs.first { $0.url == url }
            guard tab != nil else {
                throw AIToolBridgeError.tabNotOpen(url.absoluteString)
            }
        } else {
            tab = model.activeTab
        }

        guard let engine = tab?.engine, let data = await engine.captureSnapshot() else {
            throw AIToolBridgeError.screenshotFailed
        }
        let name = tab?.url?.host ?? "page"
        return AIToolOutput(
            text: "Screenshot of \(tab?.url?.absoluteString ?? name) attached.",
            attachments: [
                AIAttachment(
                    kind: .image,
                    name: "\(name).jpg",
                    mediaType: "image/jpeg",
                    data: data
                )
            ]
        )
    }

    private func runPython(_ arguments: AIJSONValue) async throws -> AIToolOutput {
        guard let code = arguments["code"]?.stringValue, !code.isEmpty else {
            throw AIToolBridgeError.invalidArguments
        }
        return AIToolOutput(text: try await PythonToolRunner.run(code: code))
    }

    // MARK: - Tabs

    private func runListTabs() -> AIToolOutput {
        guard let model, !model.tabs.isEmpty else {
            return AIToolOutput(text: "No tabs are open.")
        }
        let listing = model.tabs.map { tab in
            let folder = tab.folderID.flatMap { model.folderPath($0) }
            let suffix = folder.map { " [folder: \($0)]" } ?? ""
            return "\(tab.id.rawValue.uuidString) — \(tab.displayTitle) — "
                + "\(tab.url?.absoluteString ?? "")\(suffix)"
        }.joined(separator: "\n")
        return AIToolOutput(text: listing)
    }

    private func runGroupTabs(_ arguments: AIJSONValue) throws -> AIToolOutput {
        guard let model else { throw AIToolBridgeError.windowClosed }
        guard let name = arguments["name"]?.stringValue, !name.isEmpty,
              case let .array(rawIDs)? = arguments["tab_ids"]
        else { throw AIToolBridgeError.invalidArguments }

        let requested = Set(
            rawIDs
                .compactMap(\.stringValue)
                .compactMap(UUID.init(uuidString:))
                .map(TabID.init)
        )
        let known = Set(model.tabs.map(\.id)).intersection(requested)
        guard !known.isEmpty else {
            throw AIToolBridgeError.invalidArguments
        }
        // Ignore an unknown symbol rather than failing the call over an icon.
        let icon = arguments["icon"]?.stringValue
            .flatMap { Self.folderSymbolNames.contains($0) ? $0 : nil }
        model.createNamedFolder(name, symbolName: icon, containing: known)
        return AIToolOutput(text: "Moved \(known.count) tab(s) into “\(name)”.")
    }

    /// The same icons the sidebar's own folder menu offers.
    private static let folderSymbolNames = FolderSymbolOption.popular.map(\.symbolName)

    // MARK: - Memory

    private func runRemember(_ arguments: AIJSONValue) throws -> AIToolOutput {
        guard let text = arguments["text"]?.stringValue,
              let memory = memories.remember(text)
        else { throw AIToolBridgeError.invalidArguments }
        return AIToolOutput(text: "Remembered as [\(memory.shortID)].")
    }

    private func runRecallMemories(_ arguments: AIJSONValue) -> AIToolOutput {
        let limit = arguments["limit"].flatMap(Self.intValue) ?? 20
        return AIToolOutput(text: Self.render(memories.recent(limit: max(1, limit))))
    }

    private func runSearchMemories(_ arguments: AIJSONValue) throws -> AIToolOutput {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw AIToolBridgeError.invalidArguments
        }
        return AIToolOutput(text: Self.render(memories.search(query)))
    }

    private func runForgetMemory(_ arguments: AIJSONValue) throws -> AIToolOutput {
        guard let identifier = arguments["id"]?.stringValue else {
            throw AIToolBridgeError.invalidArguments
        }
        let removed = memories.forget(identifier: identifier)
        return AIToolOutput(
            text: removed ? "Forgotten." : "No memory with id \(identifier)."
        )
    }

    private static func render(_ memories: [AIMemory]) -> String {
        guard !memories.isEmpty else { return "Nothing remembered yet." }
        return memories.map { "[\($0.shortID)] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Schema helpers

    private func spec(
        _ name: String,
        _ description: String,
        properties: [String: AIJSONValue],
        required: [String]
    ) -> AIToolSpec {
        AIToolSpec(
            name: name,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(AIJSONValue.string))
            ])
        )
    }

    private func string(_ description: String) -> AIJSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private func boolean(_ description: String) -> AIJSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private func stringEnum(_ description: String, values: [String]) -> AIJSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map(AIJSONValue.string))
        ])
    }

    private func number(_ description: String) -> AIJSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private func array(_ description: String, itemDescription: String) -> AIJSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("string"),
                "description": .string(itemDescription)
            ])
        ])
    }

    private static func intValue(_ value: AIJSONValue) -> Int? {
        if case let .number(number) = value { return Int(number) }
        return nil
    }

    private static func webURL(from raw: String?) throws -> URL {
        guard let raw,
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { throw AIToolBridgeError.invalidArguments }
        return url
    }
}

enum AIToolBridgeError: LocalizedError {
    case unknownTool(String)
    case invalidArguments
    case windowClosed
    case tabNotOpen(String)
    case screenshotFailed

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            "Unknown tool: \(name)"
        case .invalidArguments:
            "Invalid tool arguments."
        case .windowClosed:
            "The browser window is no longer available."
        case let .tabNotOpen(url):
            "No open tab for \(url). Open it first with open_tab."
        case .screenshotFailed:
            "The page could not be captured."
        }
    }
}

/// Hands a chat session from a browser window to the detached chat window.
/// Mirrors `BrowserWindowTransferCenter` for tabs.
@MainActor
public final class AIChatWindowBridge {
    public static let shared = AIChatWindowBridge()

    private var staged: [UUID: AIChatSession] = [:]

    private init() {}

    func stage(_ session: AIChatSession, token: UUID) {
        staged[token] = session
    }

    public func claim(_ token: UUID) -> AIChatSession? {
        staged.removeValue(forKey: token)
    }
}
