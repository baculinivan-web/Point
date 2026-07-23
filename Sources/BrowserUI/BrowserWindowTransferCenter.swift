import Observation

@MainActor
@Observable
public final class BrowserWindowTransferCenter {
    public static let shared = BrowserWindowTransferCenter()

    private var pendingBatches: [[BrowserTab]] = []

    private init() {}

    func stage(_ tabs: [BrowserTab]) {
        guard !tabs.isEmpty else { return }
        pendingBatches.append(tabs)
    }

    public func claimNextBatch() -> [BrowserTab]? {
        guard !pendingBatches.isEmpty else { return nil }
        return pendingBatches.removeFirst()
    }
}
