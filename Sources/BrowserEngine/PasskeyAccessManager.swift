import AuthenticationServices
import Observation

public enum PasskeyAccessState: Sendable {
    case authorized
    case denied
    case notDetermined
}

@MainActor
@Observable
public final class PasskeyAccessManager {
    public static let shared = PasskeyAccessManager()

    public private(set) var state: PasskeyAccessState
    public private(set) var isDeviceConfiguredForPasskeys: Bool

    @ObservationIgnored private let manager: ASAuthorizationWebBrowserPublicKeyCredentialManager
    @ObservationIgnored private var accessRequestIsInFlight = false
    @ObservationIgnored private var accessRequestCompletions: [
        @MainActor (PasskeyAccessState) -> Void
    ] = []

    public init() {
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        self.manager = manager
        state = Self.map(manager.authorizationStateForPlatformCredentials)
        isDeviceConfiguredForPasskeys = Self.deviceIsConfiguredForPasskeys
    }

    /// Refreshes values that can change while the app is open, for example after
    /// the user changes passkey access in System Settings.
    @discardableResult
    public func refreshState() -> PasskeyAccessState {
        state = Self.map(manager.authorizationStateForPlatformCredentials)
        isDeviceConfiguredForPasskeys = Self.deviceIsConfiguredForPasskeys
        return state
    }

    /// Requests browser-wide passkey access before WebKit creates its first page.
    /// This makes WebAuthn's platform-authenticator capability probe return the
    /// real device state on the page's initial load.
    @discardableResult
    public func prepareForWebBrowsing() async -> PasskeyAccessState {
        let currentState = refreshState()
        guard currentState == .notDetermined else { return currentState }

        return await withCheckedContinuation { continuation in
            requestAccess { state in
                continuation.resume(returning: state)
            }
        }
    }

    public func requestAccess(
        completion: (@MainActor (PasskeyAccessState) -> Void)? = nil
    ) {
        let currentState = refreshState()
        guard currentState == .notDetermined else {
            completion?(currentState)
            return
        }

        if let completion {
            accessRequestCompletions.append(completion)
        }
        guard !accessRequestIsInFlight else { return }
        accessRequestIsInFlight = true

        manager.requestAuthorizationForPublicKeyCredentials { [weak self] authorizationState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let state = Self.map(authorizationState)
                self.state = state
                self.isDeviceConfiguredForPasskeys = Self.deviceIsConfiguredForPasskeys
                self.accessRequestIsInFlight = false
                let completions = self.accessRequestCompletions
                self.accessRequestCompletions.removeAll()
                completions.forEach { $0(state) }
            }
        }
    }

    private static var deviceIsConfiguredForPasskeys: Bool {
        if #available(macOS 26.2, *) {
            ASAuthorizationWebBrowserPublicKeyCredentialManager
                .isDeviceConfiguredForPasskeys
        } else {
            true
        }
    }

    private static func map(
        _ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> PasskeyAccessState {
        switch state {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }
}
