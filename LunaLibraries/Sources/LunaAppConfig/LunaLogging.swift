import Foundation

/// The `os.Logger` subsystem every `Logger(subsystem:category:)` call site in
/// the app, the package and the Safari appex shares, so Console.app / `log
/// stream --predicate` can filter on one subsystem across all of them instead
/// of three different literals.
///
/// Lives in `LunaAppConfig` because it is the lowest module every logging call
/// site already reaches: the app shell, `LunaSend`, `LunaStorage` and
/// `LunaDesignSystem` all depend on it directly, and it is part of the
/// Foundation-only floor the `LunaSafari` appexes link.
public enum LunaLogging {
    public static let subsystem = "com.hsanabria.luna"
}
