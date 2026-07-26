import BrowserAI
import BrowserCore
import Foundation
import Observation

/// Hands the assistant real browser capabilities: reading the current page,
/// searching the web, opening tabs, and reading arbitrary URLs.
@MainActor
final class BrowserAIToolBridge: AIChatToolExecutor {
    private weak var model: BrowserWindowModel?

    init(model: BrowserWindowModel) {
        self.model = model
    }

    var toolSpecs: [AIToolSpec] {
        [
            AIToolSpec(
                name: "web_search",
                description: "Search the web. Returns titles, URLs, and snippets "
                    + "of the top results.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("The search query.")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            AIToolSpec(
                name: "open_tab",
                description: "Open a URL in a new browser tab for the person. "
                    + "Set background=false only when they want to switch to it.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("Absolute http(s) URL to open.")
                        ]),
                        "background": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                "Open without switching to the tab. Default true."
                            )
                        ])
                    ]),
                    "required": .array([.string("url")])
                ])
            ),
            AIToolSpec(
                name: "read_page",
                description: "Fetch a URL and return its readable text without "
                    + "opening a visible tab.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("Absolute http(s) URL to read.")
                        ])
                    ]),
                    "required": .array([.string("url")])
                ])
            )
        ]
    }

    func currentPageContext() async -> AIPageContext? {
        guard let tab = model?.activeTab, let url = tab.url else { return nil }
        let title = tab.displayTitle
        let text = await tab.engine?.extractPageText(limit: 12000) ?? ""
        return AIPageContext(url: url, title: title, text: text)
    }

    func executeTool(name: String, arguments: AIJSONValue) async throws -> String {
        switch name {
        case "web_search":
            return try await runWebSearch(arguments)
        case "open_tab":
            return try await runOpenTab(arguments)
        case "read_page":
            return try await runReadPage(arguments)
        default:
            throw AIToolBridgeError.unknownTool(name)
        }
    }

    private func runWebSearch(_ arguments: AIJSONValue) async throws -> String {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw AIToolBridgeError.invalidArguments
        }
        let results = try await AIWebSearch.search(query: query)
        guard !results.isEmpty else { return "No results found." }
        return results.enumerated().map { index, result in
            """
            \(index + 1). \(result.title)
            \(result.url.absoluteString)
            \(result.snippet)
            """
        }.joined(separator: "\n\n")
    }

    private func runOpenTab(_ arguments: AIJSONValue) async throws -> String {
        let url = try Self.webURL(from: arguments["url"]?.stringValue)
        let inBackground = arguments["background"]?.boolValue ?? true
        guard let model else { throw AIToolBridgeError.windowClosed }
        model.openAssistantTab(url: url, inBackground: inBackground)
        return "Opened \(url.absoluteString) in a \(inBackground ? "background" : "foreground") tab."
    }

    private func runReadPage(_ arguments: AIJSONValue) async throws -> String {
        let url = try Self.webURL(from: arguments["url"]?.stringValue)
        // Prefer the live tab when the page is already loaded: it reflects the
        // rendered DOM, including client-side content a plain fetch would miss.
        if let tab = model?.tabs.first(where: { $0.url == url }),
           let engine = tab.engine,
           let text = await engine.extractPageText(limit: 12000),
           !text.isEmpty {
            return text
        }
        return try await AIWebSearch.fetchPlainText(url: url)
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

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            "Unknown tool: \(name)"
        case .invalidArguments:
            "Invalid tool arguments."
        case .windowClosed:
            "The browser window is no longer available."
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
