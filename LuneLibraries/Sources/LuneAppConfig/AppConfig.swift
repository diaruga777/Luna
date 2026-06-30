import Foundation

/// Single source of truth for the shared **App Group** and **iCloud container**
/// identifiers used across the app(s) and every bundled extension.
///
/// The real values are injected at build time from `Config/Lune.xcconfig`
/// (`$(APP_GROUP_ID)` / `$(ICLOUD_CONTAINER_ID)`) into **every** target's `Info.plist`
/// as `LuneAppGroupID` / `LuneICloudContainerID`, and read here at runtime via
/// `Bundle.main`. Because `Bundle.main` resolves to each process's own bundle (the app
/// or the `.appex`), the app and all of its extensions resolve to the *same* shared
/// identifiers — which is what makes the shared on-disk store work cross-process.
///
/// Net effect: renaming the product namespace is a **one-line edit** in the xcconfig
/// (`LUNE_NAMESPACE`); no Swift changes are required.
///
/// The compiled-in defaults are a safety net only. In a correctly configured build the
/// Info.plist values always win. `resolvedFromInfoPlist` lets a host assert at launch
/// that the xcconfig → Info.plist chain is intact, so a misconfiguration can never
/// silently fall back and split the shared App Group container.
public enum AppConfig {
    /// Shared App Group identifier, e.g. `group.com.hsanabria.lune`.
    public static let appGroupID: String =
        string(forInfoKey: appGroupInfoKey) ?? defaultAppGroupID

    /// Shared iCloud (CloudKit) container identifier, e.g. `iCloud.com.hsanabria.lune`.
    public static let iCloudContainerID: String =
        string(forInfoKey: iCloudContainerInfoKey) ?? defaultICloudContainerID

    /// `true` when both identifiers were resolved from the build-injected Info.plist
    /// (vs. the compiled-in fallbacks). Hosts should `assert(AppConfig.resolvedFromInfoPlist)`
    /// at launch in DEBUG to catch a broken xcconfig → Info.plist chain immediately.
    public static var resolvedFromInfoPlist: Bool {
        string(forInfoKey: appGroupInfoKey) != nil
            && string(forInfoKey: iCloudContainerInfoKey) != nil
    }

    // MARK: - Internals

    static let appGroupInfoKey = "LuneAppGroupID"
    static let iCloudContainerInfoKey = "LuneICloudContainerID"

    /// Fallbacks must match the values derived in `Config/Lune.xcconfig` for the
    /// default `LUNE_NAMESPACE = lune`. Kept in sync by `LuneAppConfigTests`.
    static let defaultAppGroupID = "group.com.hsanabria.lune"
    static let defaultICloudContainerID = "iCloud.com.hsanabria.lune"

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
