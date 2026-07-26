import AppKit
import Foundation

/// Reads and updates Point's `http` and `https` Launch Services associations.
///
/// Both schemes must point to Point before it is presented as the default
/// browser. macOS may ask the person using the Mac to approve this change.
@MainActor
public enum DefaultBrowserService {
    private static let webSchemes = ["http", "https"]

    public static func isDefaultBrowser(
        applicationURL: URL = Bundle.main.bundleURL
    ) -> Bool {
        let applicationURL = canonicalApplicationURL(applicationURL)
        return webSchemes.allSatisfy { scheme in
            guard let handlerURL = NSWorkspace.shared.urlForApplication(
                toOpen: URL(string: "\(scheme)://example.com")!
            ) else {
                return false
            }
            return canonicalApplicationURL(handlerURL) == applicationURL
        }
    }

    public static func makeDefaultBrowser(
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        let applicationURL = Bundle.main.bundleURL
        setDefaultApplication(
            at: applicationURL,
            forSchemeAt: 0,
            completion: completion
        )
    }

    private static func setDefaultApplication(
        at applicationURL: URL,
        forSchemeAt index: Int,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        guard webSchemes.indices.contains(index) else {
            completion(nil)
            return
        }

        NSWorkspace.shared.setDefaultApplication(
            at: applicationURL,
            toOpenURLsWithScheme: webSchemes[index]
        ) { error in
            Task { @MainActor in
                guard error == nil else {
                    completion(error)
                    return
                }
                setDefaultApplication(
                    at: applicationURL,
                    forSchemeAt: index + 1,
                    completion: completion
                )
            }
        }
    }

    private static func canonicalApplicationURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
