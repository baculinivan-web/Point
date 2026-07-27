@preconcurrency import AppKit
import Foundation
import WebKit

public enum AgentDriverError: LocalizedError {
    case scriptFailed(String)
    case staleReference(String)
    case notInteractable(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case let .scriptFailed(detail):
            "The page could not be inspected: \(detail)"
        case let .staleReference(ref):
            "Element \(ref) is gone — the page changed. Take a fresh "
                + "browser_snapshot and use the new refs."
        case let .notInteractable(detail):
            detail
        case let .timedOut(detail):
            "Timed out waiting for \(detail)."
        }
    }
}

/// Where an action landed, in fractions of the web view, for the overlay.
private struct AgentHit {
    let cssX: Double
    let cssY: Double
    let fractionX: Double
    let fractionY: Double
    let fractionWidth: Double
    let fractionHeight: Double
}

/// Drives one page: reads its structure, clicks, types, scrolls, waits.
///
/// WebKit exposes no automation protocol — there is no CDP behind `WKWebView`
/// and `safaridriver` only attaches to Safari — so perception runs through
/// JavaScript in an isolated content world, and clicks are posted as real
/// AppKit events. Real events matter: synthetic `element.click()` misses
/// anything gated on `isTrusted`, and never reaches native `<select>` popups
/// or canvas-backed UIs.
@MainActor
public final class AgentPageDriver {
    /// The agent's private JavaScript world. The page shares no globals with
    /// it, so a hostile site can neither read the agent's helpers nor replace
    /// them with ones that lie about the DOM.
    private static let world = WKContentWorld.world(name: "PointAgentDriver")

    private let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Perception

    public func snapshot(
        maxElements: Int = 120,
        textLimit: Int = 3000
    ) async throws -> AgentPageSnapshot {
        let json = try await callJSON(
            "await globalThis.__pointAgent.snapshot(maxElements, textLimit)",
            arguments: ["maxElements": maxElements, "textLimit": textLimit]
        )
        guard let data = json.data(using: .utf8) else {
            throw AgentDriverError.scriptFailed("the snapshot was not valid text")
        }
        do {
            return try JSONDecoder().decode(AgentPageSnapshot.self, from: data)
        } catch {
            throw AgentDriverError.scriptFailed(error.localizedDescription)
        }
    }

    // MARK: - Actions

    /// Clicks an element, preferring a real AppKit event and falling back to a
    /// DOM click when the page cannot be aimed at (tab not on screen, element
    /// scrolled somewhere unreachable).
    @discardableResult
    public func click(ref: String) async throws -> AgentClickOutcome {
        let location = try await locate(ref: ref)

        if location.ok, let hit = hit(for: location), postNativeClick(at: hit) {
            return AgentClickOutcome(
                usedNativeEvent: true,
                fractionX: hit.fractionX,
                fractionY: hit.fractionY,
                name: location.name,
                role: location.role
            )
        }

        let json = try await callJSON(
            "await globalThis.__pointAgent.domClick(ref)",
            arguments: ["ref": ref]
        )
        let result = try decodeResult(json)
        guard result.ok else {
            throw result.reason == "stale"
                ? AgentDriverError.staleReference(ref)
                : AgentDriverError.notInteractable(
                    "Element \(ref) could not be clicked (\(result.reason))."
                )
        }
        let hit = self.hit(for: location)
        return AgentClickOutcome(
            usedNativeEvent: false,
            fractionX: hit?.fractionX ?? 0.5,
            fractionY: hit?.fractionY ?? 0.5,
            name: location.name,
            role: location.role
        )
    }

    /// Fills a field. Goes through the native value setter and fires
    /// input/change, which is what framework-backed pages listen for; setting
    /// `.value` alone gets silently reverted on the next render.
    @discardableResult
    public func type(
        ref: String,
        text: String,
        replacingExisting: Bool
    ) async throws -> AgentTypeOutcome {
        let json = try await callJSON(
            "await globalThis.__pointAgent.fill(ref, text, replace)",
            arguments: ["ref": ref, "text": text, "replace": replacingExisting]
        )
        let result = try decodeResult(json)
        guard result.ok else {
            throw result.reason == "stale"
                ? AgentDriverError.staleReference(ref)
                : AgentDriverError.notInteractable(
                    "Element \(ref) does not accept typing (\(result.reason))."
                )
        }
        let rect = fractionRect(
            left: result.left,
            top: result.top,
            width: result.width,
            height: result.height,
            viewportWidth: result.viewportWidth,
            viewportHeight: result.viewportHeight
        )
        return AgentTypeOutcome(
            fractionX: rect.fractionX,
            fractionY: rect.fractionY,
            fractionWidth: rect.fractionWidth,
            fractionHeight: rect.fractionHeight
        )
    }

    public func selectOption(ref: String, label: String) async throws -> String {
        let json = try await callJSON(
            "await globalThis.__pointAgent.selectOption(ref, label)",
            arguments: ["ref": ref, "label": label]
        )
        let result = try decodeResult(json)
        guard result.ok else {
            if result.reason == "stale" { throw AgentDriverError.staleReference(ref) }
            let options = result.available.isEmpty
                ? ""
                : " Available options: " + result.available.joined(separator: ", ")
            throw AgentDriverError.notInteractable(
                "Could not select “\(label)” in \(ref).\(options)"
            )
        }
        return result.selected
    }

    public func pressEnter(ref: String?) async throws {
        _ = try await callJSON(
            "await globalThis.__pointAgent.pressEnter(ref)",
            arguments: ["ref": ref as Any]
        )
    }

    @discardableResult
    public func scroll(dx: Double, dy: Double) async throws -> AgentScrollOutcome {
        let json = try await callJSON(
            "await globalThis.__pointAgent.scroll(dx, dy)",
            arguments: ["dx": dx, "dy": dy]
        )
        let result = try decodeResult(json)
        return AgentScrollOutcome(
            from: result.from,
            to: result.to,
            scrollHeight: result.scrollHeight,
            viewportHeight: result.viewportHeight
        )
    }

    /// Polls until the document finishes loading, or gives up.
    ///
    /// Deliberately a poll rather than a navigation-delegate hook: the agent
    /// also has to wait out same-page transitions that fire no navigation at
    /// all, which is most of the modern web.
    public func waitUntilLoaded(timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !webView.isLoading {
                let json = try? await callJSON(
                    "await globalThis.__pointAgent.readyState()"
                )
                if let json, let result = try? decodeResult(json),
                   result.readyState == "complete" {
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw AgentDriverError.timedOut("the page to finish loading")
    }

    // MARK: - Native event injection

    /// Posts a real mouse click at the element's centre.
    ///
    /// Returns false when the geometry cannot be trusted — no window, the tab
    /// is not the visible one, or the point falls outside the view — and the
    /// caller falls back to a DOM click rather than clicking blindly.
    private func postNativeClick(at hit: AgentHit) -> Bool {
        guard let window = webView.window,
              window.isVisible,
              webView.superview != nil,
              webView.bounds.width > 1, webView.bounds.height > 1
        else { return false }

        let zoom = webView.pageZoom
        let x = hit.cssX * zoom
        let yFromTop = hit.cssY * zoom
        guard x >= 0, yFromTop >= 0,
              x <= webView.bounds.width, yFromTop <= webView.bounds.height
        else { return false }

        // WKWebView is not a flipped view, so CSS's top-down y has to be
        // measured from the bottom before AppKit will accept it.
        let viewPoint = CGPoint(x: x, y: webView.bounds.height - yFromTop)
        let windowPoint = webView.convert(viewPoint, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime

        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.03,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return false }

        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    // MARK: - Geometry

    private func hit(for location: AgentScriptResult) -> AgentHit? {
        guard location.viewportWidth > 1, location.viewportHeight > 1 else {
            return nil
        }
        let rect = fractionRect(
            left: location.x,
            top: location.y,
            width: 0,
            height: 0,
            viewportWidth: location.viewportWidth,
            viewportHeight: location.viewportHeight
        )
        return AgentHit(
            cssX: location.x,
            cssY: location.y,
            fractionX: rect.fractionX,
            fractionY: rect.fractionY,
            fractionWidth: 0,
            fractionHeight: 0
        )
    }

    private func fractionRect(
        left: Double,
        top: Double,
        width: Double,
        height: Double,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> AgentHit {
        guard viewportWidth > 1, viewportHeight > 1 else {
            return AgentHit(
                cssX: left, cssY: top,
                fractionX: 0.5, fractionY: 0.5,
                fractionWidth: 0, fractionHeight: 0
            )
        }
        return AgentHit(
            cssX: left,
            cssY: top,
            fractionX: (left + width / 2) / viewportWidth,
            fractionY: (top + height / 2) / viewportHeight,
            fractionWidth: width / viewportWidth,
            fractionHeight: height / viewportHeight
        )
    }

    // MARK: - Bridge

    private func locate(ref: String) async throws -> AgentScriptResult {
        let json = try await callJSON(
            "await globalThis.__pointAgent.locate(ref)",
            arguments: ["ref": ref]
        )
        let result = try decodeResult(json)
        if result.reason == "stale" {
            throw AgentDriverError.staleReference(ref)
        }
        return result
    }

    private func callJSON(
        _ expression: String,
        arguments: [String: Any] = [:]
    ) async throws -> String {
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                PageAgentScript.call(expression),
                arguments: arguments,
                contentWorld: Self.world
            )
        } catch {
            throw AgentDriverError.scriptFailed(error.localizedDescription)
        }
        guard let json = value as? String else {
            throw AgentDriverError.scriptFailed("the page returned nothing")
        }
        return json
    }

    private func decodeResult(_ json: String) throws -> AgentScriptResult {
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(AgentScriptResult.self, from: data)
        else {
            throw AgentDriverError.scriptFailed("the page returned an unreadable result")
        }
        return result
    }
}

/// The loosely-typed envelope every action helper returns.
private struct AgentScriptResult: Decodable {
    var ok = false
    var reason = ""
    var selected = ""
    var available: [String] = []
    var readyState = ""
    var name = ""
    var role = ""
    var x: Double = 0
    var y: Double = 0
    var left: Double = 0
    var top: Double = 0
    var width: Double = 0
    var height: Double = 0
    var viewportWidth: Double = 0
    var viewportHeight: Double = 0
    var from: Double = 0
    var to: Double = 0
    var scrollHeight: Double = 0

    private enum CodingKeys: String, CodingKey {
        case ok, reason, selected, available, readyState, name, role
        case x, y, left, top, width, height
        case viewportWidth, viewportHeight
        case from, to, scrollHeight
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        selected = try container.decodeIfPresent(String.self, forKey: .selected) ?? ""
        available = try container.decodeIfPresent([String].self, forKey: .available) ?? []
        readyState = try container.decodeIfPresent(String.self, forKey: .readyState) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        left = try container.decodeIfPresent(Double.self, forKey: .left) ?? 0
        top = try container.decodeIfPresent(Double.self, forKey: .top) ?? 0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
        viewportWidth = try container.decodeIfPresent(
            Double.self, forKey: .viewportWidth
        ) ?? 0
        viewportHeight = try container.decodeIfPresent(
            Double.self, forKey: .viewportHeight
        ) ?? 0
        from = try container.decodeIfPresent(Double.self, forKey: .from) ?? 0
        to = try container.decodeIfPresent(Double.self, forKey: .to) ?? 0
        scrollHeight = try container.decodeIfPresent(
            Double.self, forKey: .scrollHeight
        ) ?? 0
    }
}

public struct AgentClickOutcome: Sendable {
    public let usedNativeEvent: Bool
    public let fractionX: Double
    public let fractionY: Double
    public let name: String
    public let role: String
}

public struct AgentTypeOutcome: Sendable {
    public let fractionX: Double
    public let fractionY: Double
    public let fractionWidth: Double
    public let fractionHeight: Double
}

public struct AgentScrollOutcome: Sendable {
    public let from: Double
    public let to: Double
    public let scrollHeight: Double
    public let viewportHeight: Double
}
