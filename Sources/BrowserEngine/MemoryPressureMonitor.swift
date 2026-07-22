@preconcurrency import Dispatch
import BrowserCore

public final class MemoryPressureMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure
    private let handler: @MainActor @Sendable (MemoryPressureLevel) -> Void
    private var isStarted = false

    public init(
        handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void
    ) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        self.handler = handler
        source.setEventHandler { [source, handler] in
            let level: MemoryPressureLevel = source.data.contains(.critical)
                ? .critical
                : .warning
            MainActor.assumeIsolated {
                handler(level)
            }
        }
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        source.activate()
    }

    public func cancel() {
        guard isStarted else { return }
        source.cancel()
        isStarted = false
    }

    deinit {
        if isStarted {
            source.cancel()
        }
    }
}
