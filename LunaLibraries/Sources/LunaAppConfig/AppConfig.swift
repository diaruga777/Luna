import Foundation

/// Single source of truth for the shared **App Group** identifier used across
/// the app(s) and every bundled extension.
///
/// The real value is injected at build time from `Config/Luna.xcconfig`
/// (`$(APP_GROUP_ID)`) into **every** target's `Info.plist` as `LunaAppGroupID`,
/// and read here at runtime via `Bundle.main`. Because `Bundle.main` resolves to
/// each process's own bundle (the app or the `.appex`), the app and all of its
/// extensions resolve to the *same* shared identifier — which is what makes the
/// shared on-disk store work cross-process.
///
/// Net effect: renaming the product namespace is a **one-line edit** in the xcconfig
/// (`LUNA_NAMESPACE`); no Swift changes are required.
///
/// The compiled-in default is a safety net only. In a correctly configured build the
/// Info.plist value always wins. `resolvedFromInfoPlist` lets a host assert at launch
/// that the xcconfig → Info.plist chain is intact, so a misconfiguration can never
/// silently fall back and split the shared App Group container.
public enum AppConfig {
    /// Shared App Group identifier, e.g. `group.com.hsanabria.luna`.
    public static let appGroupID: String =
        string(forInfoKey: appGroupInfoKey) ?? defaultAppGroupID

    /// `true` when the identifier was resolved from the build-injected Info.plist
    /// (vs. the compiled-in fallback). Hosts should `assert(AppConfig.resolvedFromInfoPlist)`
    /// at launch in DEBUG to catch a broken xcconfig → Info.plist chain immediately.
    public static var resolvedFromInfoPlist: Bool {
        string(forInfoKey: appGroupInfoKey) != nil
    }

    /// This build's identity, `"<short version> (<build>)"` — e.g. `"1.4 (208)"`.
    ///
    /// Used as a *generation marker* for work that should be retried exactly once
    /// per shipped version: a failed save whose Apple Intelligence rescue was
    /// already spent under this version stays terminal, and an app update makes
    /// every one of them eligible again (`SaveFailureRecord.aiAttemptVersion`).
    /// Both components matter — a TestFlight build bump with no version change
    /// still carries new extraction code.
    public static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()

    // MARK: - Internals

    static let appGroupInfoKey = "LunaAppGroupID"

    /// Fallback must match the value derived in `Config/Luna.xcconfig` for the
    /// default `LUNA_NAMESPACE = luna`. Kept in sync by `LunaAppConfigTests`.
    static let defaultAppGroupID = "group.com.hsanabria.luna"

    private static func string(forInfoKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded build variable (e.g. literal "$(APP_GROUP_ID)") is treated as
        // unresolved so the fallback — and the resolvedFromInfoPlist assert — catch it.
        if trimmed.isEmpty || trimmed.hasPrefix("$(") {
            return nil
        }
        return trimmed
    }
}
