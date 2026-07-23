import Foundation

public enum BrowserMemoryLimitSettings {
    public static let defaultsKey = "BrowserMemoryLimitFraction"
    public static let defaultFraction = 0.5
    public static let allowedRange = 0.25...0.9

    public static func normalizedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFraction }
        return min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }

    public static func currentFraction(
        userDefaults: UserDefaults = .standard
    ) -> Double {
        guard userDefaults.object(forKey: defaultsKey) != nil else {
            return defaultFraction
        }
        return normalizedFraction(userDefaults.double(forKey: defaultsKey))
    }
}

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

    public init(backgroundIdleTimeout: TimeInterval = 600) {
        self.backgroundIdleTimeout = backgroundIdleTimeout
    }

    public func memoryBudget(
        physicalMemoryBytes: UInt64,
        limitFraction: Double = BrowserMemoryLimitSettings.defaultFraction
    ) -> UInt64 {
        let fraction = BrowserMemoryLimitSettings.normalizedFraction(limitFraction)
        return UInt64(Double(physicalMemoryBytes) * fraction)
    }

    public func actions(
        for tabs: [TabLifecycleSnapshot],
        selectedTabID: TabID?,
        now: Date,
        physicalMemoryBytes: UInt64,
        memoryLimitFraction: Double = BrowserMemoryLimitSettings.defaultFraction,
        browserMemoryBytes: UInt64,
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
        let budget = memoryBudget(
            physicalMemoryBytes: physicalMemoryBytes,
            limitFraction: memoryLimitFraction
        )
        let candidates = resident
            .filter { tab in
                guard tab.id != selectedTabID else { return false }
                var protection = tab.protection
                if pressure != .normal || browserMemoryBytes > budget {
                    protection.remove(.gracePeriod)
                }
                return protection.isEmpty
            }
            .sorted { lhs, rhs in
                if lhs.lastInteractionAt == rhs.lastInteractionAt {
                    return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                }
                return lhs.lastInteractionAt < rhs.lastInteractionAt
            }
        let evictionCount: Int
        if pressure == .critical {
            evictionCount = candidates.count
        } else if browserMemoryBytes > budget {
            // Evict one LRU tab per measurement. WebKit releases content
            // processes asynchronously, so a later sample decides whether
            // another tab must be evicted.
            evictionCount = min(1, candidates.count)
        } else {
            evictionCount = 0
        }
        let evictedIDs = Set(candidates.prefix(evictionCount).map(\.id))
        let shouldSuspendForThermalState: Bool
        switch thermalState {
        case .serious, .critical:
            shouldSuspendForThermalState = true
        case .nominal, .fair:
            shouldSuspendForThermalState = false
        }

        for candidate in candidates where !evictedIDs.contains(candidate.id) {
            let isIdle = now.timeIntervalSince(candidate.lastInteractionAt) >= backgroundIdleTimeout
            if candidate.state == .liveBackground,
               pressure == .warning
                    || !applicationIsActive
                    || shouldSuspendForThermalState
                    || isIdle {
                actions.append(.suspend(candidate.id))
            }
        }
        actions.append(contentsOf: candidates.prefix(evictionCount).map { .evict($0.id) })
        return actions
    }
}
