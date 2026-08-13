//
//  StageContainer.swift
//  LunaAppConfig
//

import Foundation

/// The **statelessness half of staged mode** (`claudedocs/staging.md`): while a
/// stage is running, every App-Group-backed store — files and `UserDefaults`
/// alike — is pointed at a throwaway location that is created fresh at launch
/// and never read again.
///
/// It lives in `LunaAppConfig`, at the very bottom of the layer stack, because
/// that is where the two things every shared store resolves from already live:
/// `AppConfig.appGroupID` (the `UserDefaults` suite name, read by two dozen
/// stores) and `AppConfig.sharedContainerURL()` (the directory). Redirecting
/// those two is the whole mechanism — no store needs a seam of its own, and
/// nothing about the production path changes.
///
/// DEBUG-only: the type compiles to an empty shell in release, so a shipped
/// build has no way to redirect its own container. See the `#if DEBUG` note in
/// `claudedocs/staging.md` for why that, rather than a build setting, is the
/// gate.
public enum StageContainer {

    #if DEBUG

    /// The scratch directory standing in for the App Group container, or nil
    /// when no stage is running. Set once, before anything touches a store.
    public private(set) static var directory: URL?

    /// The suite name standing in for the App Group's `UserDefaults`, or nil.
    /// Distinct per activation, so two staged launches never see each other's
    /// preferences.
    public private(set) static var appGroupIDOverride: String?

    /// Stand-in for `UserDefaults.standard` while a stage runs, or nil.
    ///
    /// The App-Group redirect above covers everything SHARED between the apps.
    /// `AppOnboardingStore` deliberately uses standard defaults instead — every
    /// host owns its own onboarding — so it needs its own redirect or a staged
    /// run would answer the real install's first-run card.
    public private(set) static var standardDefaultsOverride: UserDefaults?

    /// Whether a stage owns the container right now.
    public static var isActive: Bool { directory != nil }

    /// Redirects the shared container to a freshly created scratch directory
    /// and a scratch defaults suite, both named after `identifier`.
    ///
    /// Idempotent within a process (a second call is ignored) because the
    /// redirect must be a launch-time fact: a store that already resolved a
    /// path would keep writing to the old one.
    ///
    /// - Parameter identifier: a stable, filesystem-safe name for this staged
    ///   run — the stage id, so a crash leaves an obvious breadcrumb.
    @discardableResult
    public static func activate(identifier: String) -> URL {
        if let directory { return directory }
        let safe = identifier.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let name = "LunaStage-\(String(safe))-\(ProcessInfo.processInfo.processIdentifier)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        // A fresh run must not inherit the previous one's files even if the
        // temporary directory survived (the simulator's does).
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        // NOT derived from the App Group id: a suite name beginning "group."
        // is resolved by cfprefsd as an app-group container, the process is not
        // entitled to a group it invented, and the suite comes back unusable
        // ("client is not entitled") — silently sending every defaults-backed
        // store back to the REAL App Group, which is the one thing this type
        // exists to prevent.
        let suite = "LunaStage.\(name)"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        appGroupIDOverride = suite
        let standardSuite = suite + ".standard"
        let standard = UserDefaults(suiteName: standardSuite)
        standard?.removePersistentDomain(forName: standardSuite)
        standardDefaultsOverride = standard
        return url
    }

    /// Test seam: drops the redirect so a unit test that activated a stage
    /// container doesn't leak it into the rest of the suite.
    public static func deactivateForTesting() {
        if let appGroupIDOverride {
            UserDefaults(suiteName: appGroupIDOverride)?
                .removePersistentDomain(forName: appGroupIDOverride)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        appGroupIDOverride = nil
        standardDefaultsOverride = nil
    }

    #endif

    /// `UserDefaults.standard`, or the staged stand-in for it. The one call
    /// site is `AppOnboardingStore.shared`; anything else reading standard
    /// defaults is per-device configuration a stage has no business rewriting.
    public static func standardDefaults() -> UserDefaults {
        #if DEBUG
        if let standardDefaultsOverride { return standardDefaultsOverride }
        #endif
        return .standard
    }

    #if !DEBUG

    /// Staged mode does not exist in release: nothing can redirect the
    /// container, and every caller compiles down to the production path.
    public static var isActive: Bool { false }

    #endif
}

/// Whether this process was launched for a DETERMINISTIC CAPTURE — a staged
/// run (`-LunaStage`) or the UI-test seeding harness (`-uiTestState`).
///
/// Its one job is suppressing the simulator-only debug tap targets (the
/// reader's "Sim Dive"/"Sim Pop", the reading-list row ellipsis) that otherwise
/// overlay the content being captured. They stay for interactive simulator
/// automation, which passes none of these, and for unit tests, which build view
/// controllers directly.
///
/// It lives in `LunaAppConfig` because the three call sites are in three
/// different layers — the app shell and two reader view controllers in
/// LunaReaderUI — and the argument list was previously hand-copied into each.
/// It had drifted: adding `-LunaStage` to the app's copy left both readers
/// still drawing their debug pills over every staged capture.
public enum CaptureLaunch {
    private static let argumentKeys = ["-uiTestState", "-LunaStage"]

    public static var isActive: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return argumentKeys.contains { arguments.contains($0) }
    }
}
