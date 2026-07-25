//
//  UITestSeeder.swift
//  Luna
//

import LunaStorage
import Foundation
import UIKit

/// Launch-argument-driven, DEBUG-only seeding for UI tests and the screenshot
/// harness. When the app is launched with `-uiTestState <name>`, this wipes the
/// App Group reading-list store and
/// seeds it with the named `UITestState` fixture, then forces deterministic
/// conditions: animations off, no first-run prompts. Production code paths are
/// unchanged when the argument is absent — `isActive` is false and every method
/// no-ops.
///
/// Reused by:
/// - `SceneDelegate` (seeds before choosing the root view controller),
/// - the screenshot agent (drives the running app via the same launch args),
/// - unit tests (call `UITestSeeder.seedSharedStore(_:)` directly).
///
/// See `claudedocs/ui-testing.md`.
enum UITestSeeder {
    /// Launch-argument keys.
    private static let stateArg = "-uiTestState"
    private static let screenArg = "-uiTestScreen"

    /// Whether the app was launched into a UI-test seeded state.
    static var isActive: Bool {
        #if DEBUG
        return requestedState != nil
        #else
        return false
        #endif
    }

    /// Whether this process was launched by the UI-test / screenshot harness at all
    /// (a seeded state or a deep-linked screen). The screenshot
    /// agent uses this to suppress simulator-only debug tap targets (the row ellipsis,
    /// reader "Split High/Low") that otherwise overlay real content in captures. Those
    /// hooks still appear for interactive simulator automation runs (no launch arg)
    /// and in unit/snapshot tests (which build VCs directly, without these args).
    /// DEBUG-only; always false in release.
    static var isUITestLaunch: Bool {
        #if DEBUG
        return UITestLaunch.isActive
        #else
        return false
        #endif
    }

    /// The state requested on the command line, if any (and recognized). DEBUG-only —
    /// the type itself (`UITestState`) doesn't exist in release, so the whole property
    /// is compiled out (callers reference it only from `#if DEBUG`).
    #if DEBUG
    static var requestedState: UITestState? {
        guard let raw = argumentValue(for: stateArg) else { return nil }
        return UITestState(rawValue: raw)
    }
    #endif

    /// The raw name of a specific screen the harness wants deep-linked as the
    /// window root, if requested. When present, `SceneDelegate` asks
    /// `KindWiring.uiTestRootViewController(named:)` to build that screen
    /// directly instead of the reading list, so the screenshot agent can capture
    /// any screen on any device without coordinate-tapping. A raw STRING here
    /// (not `UITestScreen`) because the screen catalog compiles only into the
    /// central Luna app — the kind-woven builder can't exist in the single-kind
    /// apps. DEBUG-only.
    #if DEBUG
    static var requestedScreenName: String? {
        argumentValue(for: screenArg)
    }
    #endif

    /// Applies the seed if a state was requested: wipes + seeds the shared store and
    /// disables animations. Call once, early in scene setup. No-ops in release or
    /// when no state argument is present.
    static func applyIfNeeded() {
        #if DEBUG
        // A screen deep-link without an explicit state still wants a populated store
        // (price-editor, search read the shared store) — default to mixed.
        let state = requestedState ?? (requestedScreenName != nil ? .mixed : nil)
        guard let state else { return }
        UIView.setAnimationsEnabled(false)
        seedSharedStore(state)
        #endif
    }

    #if DEBUG
    /// When seeded, the reading list uses this as "now" for date-relative sectioning
    /// (Reading vs Archive) instead of the wall clock — so fixed-date fixtures land in
    /// the Reading section and renders are reproducible. nil = use the real clock.
    static var sectioningNow: Date?

    /// Seeds the process-wide shared store with the given state's fixture. Exposed so
    /// unit tests can reuse the exact same seeding the app performs.
    static func seedSharedStore(_ state: UITestState) {
        seed(state, into: .shared)
    }

    /// Seeds an arbitrary store (e.g. a test scratch store) with the state's fixture
    /// and pins the sectioning clock to the fixture base date.
    static func seed(_ state: UITestState, into store: ReadingListStore) {
        sectioningNow = UITestFixtures.baseDate
        resetReadingListDefaults()
        let fixture = state.fixture
        store.seedForTesting(items: fixture.items, contents: fixture.contents)
    }

    /// Resets the persisted reading-list UI prefs (filter segment, collapsed
    /// sections) so a seeded launch always starts on the All filter with the default
    /// collapsed set — neither a prior run nor a prior test can carry state in.
    static func resetReadingListDefaults() {
        UserDefaults.standard.removeObject(forKey: ReadingListViewController.filterDefaultsKey)
        UserDefaults.standard.removeObject(forKey: ReadingListViewController.collapsedDefaultsKey)
    }

    /// The value following `key` in the launch arguments (`-key value`), or nil.
    private static func argumentValue(for key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif
}
