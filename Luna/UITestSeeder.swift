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
    /// Launch-argument key.
    private static let stateArg = "-uiTestState"

    /// Whether the app was launched into a UI-test seeded state.
    static var isActive: Bool {
        #if DEBUG
        return requestedState != nil
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

    /// Applies the seed if a state was requested: wipes + seeds the shared store and
    /// disables animations. Call once, early in scene setup. No-ops in release or
    /// when no state argument is present.
    static func applyIfNeeded() {
        #if DEBUG
        guard let state = requestedState else { return }
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
        let fixture = state.fixture
        store.seedForTesting(items: fixture.items, contents: fixture.contents)
    }

    /// The value following `key` in the launch arguments (`-key value`), or nil.
    private static func argumentValue(for key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif
}
