import BrowserCore
import Foundation
import Observation

/// A thing the agent just did on the page, positioned for the overlay.
///
/// Coordinates are fractions of the web view's bounds rather than points, so
/// the marker lands in the right place regardless of how the surface is laid
/// out or resized between the action and the next frame.
public struct AgentVisualEvent: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case click
        case type
        case scroll
    }

    public let id = UUID()
    public let kind: Kind
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        kind: Kind,
        x: Double,
        y: Double,
        width: Double = 0,
        height: Double = 0
    ) {
        self.kind = kind
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
        self.width = width
        self.height = height
    }
}

/// One line in the visible record of what the agent did.
public struct AgentStep: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let text: String
    public let at: Date

    public init(text: String, at: Date = Date()) {
        self.text = text
        self.at = at
    }
}

/// Publishes what the agent is doing so the window can show it.
///
/// The indicator is drawn natively, above the web view — never injected into
/// the page. Injected chrome would reflow real sites, be visible to the page,
/// and worst of all show up in the screenshots that go back to the model,
/// which would then start reacting to its own cursor.
@MainActor
@Observable
public final class AgentActivityCenter {
    /// The tab the agent currently drives; drives the blue glow.
    public private(set) var controlledTabID: TabID?
    /// True only while a single action is in flight, so the glow can pulse.
    public private(set) var isActing = false
    public private(set) var events: [AgentVisualEvent] = []
    public private(set) var steps: [AgentStep] = []

    /// How long a click marker stays on screen.
    private static let eventLifetime: Duration = .milliseconds(1100)
    private static let maxSteps = 60

    public init() {}

    public var isControllingBrowser: Bool { controlledTabID != nil }

    public func beginControl(of tabID: TabID) {
        controlledTabID = tabID
    }

    public func endControl() {
        controlledTabID = nil
        isActing = false
        events.removeAll()
    }

    public func beginAction() { isActing = true }

    public func endAction() { isActing = false }

    public func record(_ step: String) {
        steps.append(AgentStep(text: step))
        if steps.count > Self.maxSteps {
            steps.removeFirst(steps.count - Self.maxSteps)
        }
    }

    public func clearSteps() { steps.removeAll() }

    /// Shows a marker and retires it on its own, so callers never have to.
    public func flash(_ event: AgentVisualEvent) {
        events.append(event)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.eventLifetime)
            self?.events.removeAll { $0.id == event.id }
        }
    }
}
