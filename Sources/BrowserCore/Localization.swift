import Foundation

/// Central access point for user-facing strings.
///
/// Keeping the lookup in the core module gives the app and all feature modules
/// the same resource bundle. New languages can be added to Localizable.xcstrings
/// without changing the call sites.
public enum BrowserLocalization {
    private static let bundle: Bundle = {
        if let resourcesURL = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: resourcesURL.appending(path: "Browser_BrowserCore.bundle")
           ) {
            return packagedBundle
        }
        return .module
    }()

    public static func string(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key),
            bundle: bundle
        )
    }

    public static func string(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(key),
            arguments: arguments
        )
    }
}
