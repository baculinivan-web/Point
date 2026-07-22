import Foundation

public enum MemoryPressureLevel: Sendable {
    case normal
    case warning
    case critical
}

public enum LifecycleThermalState: Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct TabProtectionReason: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let active = Self(rawValue: 1 << 0)
    public static let audibleMedia = Self(rawValue: 1 << 1)
    public static let capture = Self(rawValue: 1 << 2)
    public static let fullscreen = Self(rawValue: 1 << 3)
    public static let pendingUIFlow = Self(rawValue: 1 << 4)
    public static let gracePeriod = Self(rawValue: 1 << 5)
}

public struct TabLifecycleSnapshot: Sendable {
    public let id: TabID
    public let state: TabLifecycleState
    public let lastInteractionAt: Date
    public let protection: TabProtectionReason

    public init(
        id: TabID,
        state: TabLifecycleState,
        lastInteractionAt: Date,
        protection: TabProtectionReason
    ) {
        self.id = id
        self.state = state
        self.lastInteractionAt = lastInteractionAt
        self.protection = protection
    }
}

public enum TabLifecycleAction: Equatable, Sendable {
    case suspend(TabID)
    case resume(TabID)
    case evict(TabID)
}

public struct TabLifecyclePolicy: Sendable {
    public var backgroundIdleTimeout: TimeInterval

    public init(backgroundIdleTimeout: TimeInterval = 120) {
        self.backgroundIdleTimeout = backgroundIdleTimeout
    }

    public func residentBudget(
        physicalMemoryBytes: UInt64,
        pressure: MemoryPressureLevel = .normal,
        thermalState: LifecycleThermalState = .nominal,
        applicationIsActive: Bool = true
    ) -> Int {
        let gibibyte = UInt64(1_073_741_824)
        let base: Int
        switch physicalMemoryBytes {
        case ...(8 * gibibyte):
            base = 2
        case ...(16 * gibibyte):
            base = 4
        case ...(32 * gibibyte):
            base = 7
        default:
            base = 10
        }

        if pressure == .critical { return 1 }

        var budget = base
        if pressure == .warning || !applicationIsActive {
            budget = max(1, budget / 2)
        }
        if thermalState == .serious {
            budget = max(1, budget / 2)
        } else if thermalState == .critical {
            budget = 1
        }
        return budget
    }

    public func actions(
        for tabs: [TabLifecycleSnapshot],
        selectedTabID: TabID?,
        now: Date,
        physicalMemoryBytes: UInt64,
        pressure: MemoryPressureLevel,
        thermalState: LifecycleThermalState,
        applicationIsActive: Bool
    ) -> [TabLifecycleAction] {
        var actions: [TabLifecycleAction] = []

        if let selected = tabs.first(where: { $0.id == selectedTabID }),
           selected.state == .suspended {
            actions.append(.resume(selected.id))
        }

        let resident = tabs.filter { tab in
            switch tab.state {
            case .active, .liveBackground, .suspended, .restoring:
                true
            case .evicted, .crashed:
                false
            }
        }
        let candidates = resident
            .filter { $0.id != selectedTabID && $0.protection.isEmpty }
            .sorted { lhs, rhs in
                if lhs.lastInteractionAt == rhs.lastInteractionAt {
                    return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                }
                return lhs.lastInteractionAt < rhs.lastInteractionAt
            }

        let budget = residentBudget(
            physicalMemoryBytes: physicalMemoryBytes,
            pressure: pressure,
            thermalState: thermalState,
            applicationIsActive: applicationIsActive
        )
        let evictionCount: Int
        if pressure == .critical {
            evictionCount = candidates.count
        } else {
            evictionCount = min(candidates.count, max(0, resident.count - budget))
        }
        let evictedIDs = Set(candidates.prefix(evictionCount).map(\.id))

        for candidate in candidates where !evictedIDs.contains(candidate.id) {
            let isIdle = now.timeIntervalSince(candidate.lastInteractionAt) >= backgroundIdleTimeout
            if candidate.state == .liveBackground,
               pressure == .warning || !applicationIsActive || isIdle {
                actions.append(.suspend(candidate.id))
            }
        }
        actions.append(contentsOf: candidates.prefix(evictionCount).map { .evict($0.id) })
        return actions
    }
}
