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
    public private(set) var state: PasskeyAccessState
    public private(set) var isDeviceConfiguredForPasskeys: Bool

    @ObservationIgnored private let manager: ASAuthorizationWebBrowserPublicKeyCredentialManager

    public init() {
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        self.manager = manager
        state = Self.map(manager.authorizationStateForPlatformCredentials)
        if #available(macOS 26.2, *) {
            isDeviceConfiguredForPasskeys = ASAuthorizationWebBrowserPublicKeyCredentialManager
                .isDeviceConfiguredForPasskeys
        } else {
            isDeviceConfiguredForPasskeys = true
        }
    }

    public func requestAccess(
        completion: (@MainActor (PasskeyAccessState) -> Void)? = nil
    ) {
        manager.requestAuthorizationForPublicKeyCredentials { [weak self] authorizationState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let state = Self.map(authorizationState)
                self.state = state
                completion?(state)
            }
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
