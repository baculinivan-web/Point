import BrowserCore
import Foundation
import Testing

@Suite("Tab lifecycle policy")
struct TabLifecyclePolicyTests {
    private let gibibyte = UInt64(1_073_741_824)
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("Default memory budget is half of installed physical memory")
    func adaptiveBudget() {
        let policy = TabLifecyclePolicy()

        #expect(policy.memoryBudget(physicalMemoryBytes: 8 * gibibyte) == 4 * gibibyte)
        #expect(policy.memoryBudget(physicalMemoryBytes: 16 * gibibyte) == 8 * gibibyte)
        #expect(policy.memoryBudget(physicalMemoryBytes: 32 * gibibyte) == 16 * gibibyte)
        #expect(policy.memoryBudget(physicalMemoryBytes: 64 * gibibyte) == 32 * gibibyte)
    }

    @Test("Custom memory fraction is applied and constrained")
    func customBudget() {
        let policy = TabLifecyclePolicy()

        #expect(policy.memoryBudget(
            physicalMemoryBytes: 16 * gibibyte,
            limitFraction: 0.75
        ) == 12 * gibibyte)
        #expect(policy.memoryBudget(
            physicalMemoryBytes: 16 * gibibyte,
            limitFraction: 0.1
        ) == 4 * gibibyte)
        #expect(policy.memoryBudget(
            physicalMemoryBytes: 16 * gibibyte,
            limitFraction: 1
        ) == UInt64(Double(16 * gibibyte) * 0.9))
    }

    @Test("LRU eviction preserves active and media-protected tabs")
    func lruAndProtection() {
        let policy = TabLifecyclePolicy(backgroundIdleTimeout: 1_000)
        let active = TabID()
        let media = TabID()
        let oldest = TabID()
        let recent = TabID()
        let newer = TabID()
        let newest = TabID()
        let tabs = [
            snapshot(active, .active, age: 0, protection: .active),
            snapshot(media, .liveBackground, age: 90, protection: .audibleMedia),
            snapshot(oldest, .liveBackground, age: 80),
            snapshot(recent, .liveBackground, age: 10),
            snapshot(newer, .liveBackground, age: 8),
            snapshot(newest, .liveBackground, age: 5)
        ]

        let actions = policy.actions(
            for: tabs,
            selectedTabID: active,
            now: now,
            physicalMemoryBytes: 8 * gibibyte,
            browserMemoryBytes: 5 * gibibyte,
            pressure: .normal,
            thermalState: .nominal,
            applicationIsActive: true
        )

        #expect(actions == [.evict(oldest)])
    }

    @Test("Warning suspends survivors and evicts one LRU tab over budget")
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
            physicalMemoryBytes: 8 * gibibyte,
            browserMemoryBytes: 5 * gibibyte,
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

    @Test("Default idle timeout keeps a background tab live for five minutes")
    func generousIdleTimeout() {
        let policy = TabLifecyclePolicy()
        let active = TabID()
        let background = TabID()
        let tabs = [
            snapshot(active, .active, age: 0, protection: .active),
            snapshot(background, .liveBackground, age: 5 * 60)
        ]

        let actions = policy.actions(
            for: tabs,
            selectedTabID: active,
            now: now,
            physicalMemoryBytes: 16 * gibibyte,
            browserMemoryBytes: 3 * gibibyte,
            pressure: .normal,
            thermalState: .nominal,
            applicationIsActive: true
        )

        #expect(actions.isEmpty)
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
            browserMemoryBytes: 1 * gibibyte,
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
            browserMemoryBytes: 1 * gibibyte,
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
            browserMemoryBytes: 1 * gibibyte,
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
