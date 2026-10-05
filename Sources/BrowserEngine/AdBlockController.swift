import CryptoKit
import Foundation
import Observation
import WebKit

/// One compiled filter shared by regular, private, restored, and popup tabs.
@MainActor
@Observable
public final class AdBlockController {
    public static let shared = AdBlockController()
    public static let defaultsKey = "point.adBlock.enabled"

    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.defaultsKey)
            for controller in controllers.allObjects { apply(to: controller) }
        }
    }
    public private(set) var hasFailed = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private let protectedControllers = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private var ruleList: WKContentRuleList?
    @ObservationIgnored private var compilation: Task<WKContentRuleList, Error>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func register(_ controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller)
        Task { [weak self, weak controller] in
            guard let self, let controller else { return }
            await prepare(controller)
        }
    }

    /// Navigation waits here so the very first page is protected too.
    func prepare(_ controller: WKUserContentController) async {
        guard isEnabled else { return }
        if compilation == nil {
            compilation = Task {
                let bundle: Bundle
                if let url = Bundle.main.resourceURL?.appending(path: "Browser_BrowserEngine.bundle"),
                   let packaged = Bundle(url: url) {
                    bundle = packaged
                } else {
                    bundle = .module
                }
                guard let url = bundle.url(forResource: "rules", withExtension: "json") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let identifier = "point.adblock.\(digest)"
                guard let store = WKContentRuleListStore.default() else {
                    throw CocoaError(.fileReadUnknown)
                }
                let cached: WKContentRuleList? = await withCheckedContinuation { continuation in
                    store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                        continuation.resume(returning: list)
                    }
                }
                if let cached {
                    return cached
                }
                return try await withCheckedThrowingContinuation { continuation in
                    store.compileContentRuleList(
                        forIdentifier: identifier,
                        encodedContentRuleList: String(decoding: data, as: UTF8.self)
                    ) { list, error in
                        if let list { continuation.resume(returning: list) }
                        else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
                    }
                }
            }
        }
        do {
            ruleList = try await compilation!.value
            hasFailed = false
            apply(to: controller)
        } catch {
            hasFailed = true
        }
    }

    private func apply(to controller: WKUserContentController) {
        guard let ruleList else { return }
        // Leave other WebKit content rule lists intact.
        if isEnabled, !protectedControllers.contains(controller) {
            controller.add(ruleList)
            protectedControllers.add(controller)
        } else if !isEnabled, protectedControllers.contains(controller) {
            controller.remove(ruleList)
            protectedControllers.remove(controller)
        }
    }
}
