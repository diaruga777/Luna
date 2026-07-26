import Foundation

/// The shared lookup point for user-facing copy shipped by Luna's library modules.
///
/// Keeping the catalog in `LunaModels` gives every app and extension one translation
/// source while still resolving strings from the SwiftPM resource bundle.
public enum L10n {
    public static func string(
        _ value: String.LocalizationValue,
        table: String? = nil,
        comment: StaticString? = nil
    ) -> String {
        String(localized: value, table: table, bundle: .module, comment: comment)
    }

    /// A deferred lookup for system APIs that accept `LocalizedStringResource`
    /// rather than a resolved `String`, such as ActivityKit alerts.
    public static func resource(
        _ value: String.LocalizationValue,
        table: String? = nil,
        comment: StaticString? = nil
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            value,
            table: table,
            bundle: .atURL(Bundle.module.bundleURL),
            comment: comment)
    }
}
