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
    ///
    /// A computed property rather than a stored `let` for one reason: **staged
    /// mode** (`claudedocs/staging.md`) swaps it for a throwaway suite name so
    /// every `UserDefaults(suiteName: AppConfig.appGroupID)` in the codebase —
    /// there are two dozen — lands in a scratch domain instead of the user's
    /// real one, with no per-store plumbing. The real value is resolved once
    /// and cached in `provisionedAppGroupID`, so this stays a cheap read.
    public static var appGroupID: String {
        #if DEBUG
        if let staged = StageContainer.appGroupIDOverride { return staged }
        #endif
        return provisionedAppGroupID
    }

    /// The App Group this build is actually entitled to — never the staged
    /// override. Only the container/defaults resolution below and the
    /// misconfiguration assert have any business reading it.
    public static let provisionedAppGroupID: String =
        string(forInfoKey: appGroupInfoKey) ?? defaultAppGroupID

    /// The shared App Group **directory** — `saves.sqlite`, `Articles/`,
    /// saved media, the weekly mirror, every file-backed shared store.
    ///
    /// THE one resolution point, so staged mode can redirect the whole
    /// container at once (a stage's App-Group id is not provisioned, so asking
    /// the file manager for it would just return nil). Callers keep their own
    /// fallbacks for the misconfigured-build case.
    public static func sharedContainerURL(_ fileManager: FileManager = .default) -> URL? {
        #if DEBUG
        if let staged = StageContainer.directory { return staged }
        #endif
        return fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: provisionedAppGroupID)
    }

    /// The product bundle prefix, e.g. `com.hsanabria.luna`.
    ///
    /// Recovered from the provisioned App Group id, which `Config/Luna.xcconfig`
    /// defines as `group.$(PRODUCT_BUNDLE_PREFIX)`. Every process — app, appex,
    /// widget — reads the same injected key, so an extension resolves the same
    /// prefix its host app does, and a namespace rename still costs one
    /// xcconfig line. Never the staged override: this names the PRODUCT, and
    /// the exported document types built from it are baked into the bundle.
    public static let productBundlePrefix: String = {
        let group = provisionedAppGroupID
        guard group.hasPrefix(appGroupPrefix) else { return group }
        return String(group.dropFirst(appGroupPrefix.count))
    }()

    private static let appGroupPrefix = "group."

    /// Shared iCloud/CloudKit container identifier, e.g. `iCloud.com.hsanabria.luna`.
    ///
    /// Plumbed exactly like the App Group — `iCloud.$(PRODUCT_BUNDLE_PREFIX)`
    /// in the shared Info.plist, read here at runtime — so a namespace rename
    /// still costs one xcconfig line. Only the four APPS carry the matching
    /// entitlement; nothing in an extension reads this.
    public static let cloudKitContainerID: String =
        string(forInfoKey: cloudKitContainerInfoKey) ?? defaultCloudKitContainerID

    /// Vault's explicit configuration seam. Vault currently shares the App
    /// Group container for handoff, but its database and encrypted objects are
    /// namespaced independently (`vault.sqlite`). Keeping a dedicated Info.plist
    /// key makes a future isolated container an additive configuration change.
    public static let vaultAppGroupID: String =
        string(forInfoKey: vaultAppGroupInfoKey) ?? appGroupID

    /// Vault-only Keychain access group. The key is intentionally resolved from
    /// the Vault host/extension bundle rather than shared with the URL apps.
    public static let vaultKeychainAccessGroup: String? =
        string(forInfoKey: vaultKeychainAccessGroupInfoKey)

    /// Dedicated connection credentials shared only by Vault, Music, and Code.
    public static let macConnectionKeychainAccessGroup: String? =
        string(forInfoKey: "LunaMacKeychainAccessGroup")

    /// The Vault database filename is deliberately not `saves.sqlite`.
    public static let vaultDatabaseName: String =
        string(forInfoKey: vaultDatabaseNameInfoKey) ?? "vault.sqlite"

    /// Vault's opt-in iCloud Documents container. The current topology uses
    /// the already-provisioned Luna iCloud identifier; a future isolated
    /// container can override this key without changing backend code.
    public static let vaultICloudContainerID: String =
        string(forInfoKey: vaultICloudContainerInfoKey) ?? cloudKitContainerID

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
    static let cloudKitContainerInfoKey = "LunaCloudKitContainerID"
    static let vaultAppGroupInfoKey = "LunaVaultAppGroupID"
    static let vaultKeychainAccessGroupInfoKey = "LunaVaultKeychainAccessGroup"
    static let vaultDatabaseNameInfoKey = "LunaVaultDatabaseName"
    static let vaultICloudContainerInfoKey = "LunaVaultICloudContainerID"

    /// Fallback must match the value derived in `Config/Luna.xcconfig` for the
    /// default `LUNA_NAMESPACE = luna`. Kept in sync by `LunaAppConfigTests`.
    static let defaultAppGroupID = "group.com.hsanabria.luna"
    static let defaultCloudKitContainerID = "iCloud.com.hsanabria.luna"

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
