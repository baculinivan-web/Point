import Foundation
import Observation

/// Something the agent wants to do that the person has to authorize first.
public struct AgentConsentRequest: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Permission to drive the browser at all, asked once per conversation.
        case browserControl
        /// A single irreversible action inside an already-approved session.
        case action
    }

    public let id = UUID()
    public let kind: Kind
    /// One line naming the action, e.g. `Click “Place order”`.
    public let title: String
    /// What the agent says it is about to do, in its own words.
    public let detail: String
    /// The page the action would happen on.
    public let origin: String

    public init(kind: Kind, title: String, detail: String, origin: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.origin = origin
    }
}

/// Asks the person before the agent does anything irreversible, and blocks the
/// tool call until they answer.
///
/// Requests queue rather than replace each other: tool calls within a turn run
/// concurrently, so two of them can arrive at the gate at the same time and
/// both deserve an answer.
@MainActor
@Observable
public final class AgentConsentCenter {
    public private(set) var queue: [AgentConsentRequest] = []

    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init() {}

    /// The request the panel should be showing right now.
    public var current: AgentConsentRequest? { queue.first }

    /// Suspends until the person answers. Never throws: a refusal is an
    /// ordinary answer the model has to work with, not an error.
    public func requestApproval(_ request: AgentConsentRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.append(request)
            continuations[request.id] = continuation
        }
    }

    public func resolve(_ id: UUID, approved: Bool) {
        queue.removeAll { $0.id == id }
        continuations.removeValue(forKey: id)?.resume(returning: approved)
    }

    /// Denies everything outstanding — used when the conversation is cancelled
    /// or the window goes away, so no tool call is left hanging forever.
    public func cancelAll() {
        let pending = continuations
        continuations.removeAll()
        queue.removeAll()
        for continuation in pending.values {
            continuation.resume(returning: false)
        }
    }
}
