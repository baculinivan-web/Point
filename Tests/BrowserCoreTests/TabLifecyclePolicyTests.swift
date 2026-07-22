import BrowserCore
import Foundation
import Testing

@Suite("Tab lifecycle policy")
struct TabLifecyclePolicyTests {
    private let gibibyte = UInt64(1_073_741_824)
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("Resident budget adapts to memory, pressure, activity, and heat")
    func adaptiveBudget() {
        let policy = TabLifecyclePolicy()

        #expect(policy.residentBudget(physicalMemoryBytes: 8 * gibibyte) == 2)
        #expect(policy.residentBudget(physicalMemoryBytes: 16 * gibibyte) == 4)
        #expect(policy.residentBudget(physicalMemoryBytes: 24 * gibibyte) == 7)
        #expect(policy.residentBudget(physicalMemoryBytes: 64 * gibibyte) == 10)
        #expect(policy.residentBudget(
            physicalMemoryBytes: 16 * gibibyte,
            pressure: .warning
        ) == 2)
        #expect(policy.residentBudget(
            physicalMemoryBytes: 16 * gibibyte,
            applicationIsActive: false
        ) == 2)
        #expect(policy.residentBudget(
            physicalMemoryBytes: 32 * gibibyte,
            thermalState: .critical
        ) == 1)
    }

    @Test("LRU eviction preserves active and media-protected tabs")
    func lruAndProtection() {
        let policy = TabLifecyclePolicy(backgroundIdleTimeout: 1_000)
        let active = TabID()
        let media = TabID()
        let oldest = TabID()
        let recent = TabID()
        let tabs = [
            snapshot(active, .active, age: 0, protection: .active),
            snapshot(media, .liveBackground, age: 90, protection: .audibleMedia),
            snapshot(oldest, .liveBackground, age: 80),
            snapshot(recent, .liveBackground, age: 10)
        ]

        let actions = policy.actions(
            for: tabs,
            selectedTabID: active,
            now: now,
            physicalMemoryBytes: 8 * gibibyte,
            pressure: .normal,
            thermalState: .nominal,
            applicationIsActive: true
        )

        #expect(actions == [.evict(oldest), .evict(recent)])
    }

    @Test("Warning suspends survivors and evicts beyond half budget")
    func warningActions() {
        let policy = TabLifecyclePolicy(backgroundIdleTimeout: 1_000)
        let active = TabID()
        let oldest = TabID()
        let middle = TabID()
        let recent = TabID()
        let actions = policy.actions(
            for: [
                snapshot(active, .active, age: 0, protection: .active),
                snapshot(oldest, .liveBackground, age: 90),
                snapshot(middle, .liveBackground, age: 60),
                snapshot(recent, .liveBackground, age: 30)
            ],
            selectedTabID: active,
            now: now,
            physicalMemoryBytes: 32 * gibibyte,
            pressure: .warning,
            thermalState: .nominal,
            applicationIsActive: true
        )

        #expect(actions == [
            .suspend(middle),
            .suspend(recent),
            .evict(oldest)
        ])
    }

    @Test("Critical pressure evicts every unprotected background tab")
    func criticalPressure() {
        let policy = TabLifecyclePolicy()
        let active = TabID()
        let media = TabID()
        let capture = TabID()
        let ordinary = TabID()
        let suspended = TabID()
        let actions = policy.actions(
            for: [
                snapshot(active, .active, age: 0, protection: .active),
                snapshot(media, .liveBackground, age: 90, protection: .audibleMedia),
                snapshot(capture, .liveBackground, age: 80, protection: .capture),
                snapshot(ordinary, .liveBackground, age: 70),
                snapshot(suspended, .suspended, age: 60)
            ],
            selectedTabID: active,
            now: now,
            physicalMemoryBytes: 64 * gibibyte,
            pressure: .critical,
            thermalState: .nominal,
            applicationIsActive: true
        )

        #expect(actions == [.evict(ordinary), .evict(suspended)])
    }

    @Test("Inactive app suspends an eligible resident background tab")
    func inactiveSuspension() {
        let policy = TabLifecyclePolicy(backgroundIdleTimeout: 1_000)
        let active = TabID()
        let background = TabID()
        let actions = policy.actions(
            for: [
                snapshot(active, .active, age: 0, protection: .active),
                snapshot(background, .liveBackground, age: 5)
            ],
            selectedTabID: active,
            now: now,
            physicalMemoryBytes: 16 * gibibyte,
            pressure: .normal,
            thermalState: .nominal,
            applicationIsActive: false
        )

        #expect(actions == [.suspend(background)])
    }

    @Test("Selecting a suspended tab requests a paired resume")
    func resumeSelectedTab() {
        let policy = TabLifecyclePolicy()
        let selected = TabID()
        let actions = policy.actions(
            for: [snapshot(selected, .suspended, age: 10, protection: .active)],
            selectedTabID: selected,
            now: now,
            physicalMemoryBytes: 8 * gibibyte,
            pressure: .normal,
            thermalState: .nominal,
            applicationIsActive: true
        )

        #expect(actions == [.resume(selected)])
    }

    private func snapshot(
        _ id: TabID,
        _ state: TabLifecycleState,
        age: TimeInterval,
        protection: TabProtectionReason = []
    ) -> TabLifecycleSnapshot {
        TabLifecycleSnapshot(
            id: id,
            state: state,
            lastInteractionAt: now.addingTimeInterval(-age),
            protection: protection
        )
    }
}
