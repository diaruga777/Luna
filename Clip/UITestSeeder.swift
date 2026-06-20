//
//  UITestSeeder.swift
//  Clip
//

import Foundation
import UIKit

/// Launch-argument-driven, DEBUG-only seeding for UI tests and the screenshot
/// harness. When the app is launched with `-uiTestState <name>` (and, optionally,
/// `-uiTestOnboardingStep <index>`), this wipes the App Group reading-list store and
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
    private static let onboardingStepArg = "-uiTestOnboardingStep"

    /// Whether the app was launched into a UI-test seeded state.
    static var isActive: Bool { requestedState != nil }

    /// The state requested on the command line, if any (and recognized).
    static var requestedState: UITestState? {
        #if DEBUG
        guard let raw = argumentValue(for: stateArg) else { return nil }
        return UITestState(rawValue: raw)
        #else
        return nil
        #endif
    }

    /// The onboarding step the harness wants to land on, if requested. When present,
    /// the app should show onboarding (regardless of stored identity) starting at
    /// this step index; absent means show the main reading list.
    static var requestedOnboardingStep: Int? {
        #if DEBUG
        guard let raw = argumentValue(for: onboardingStepArg) else { return nil }
        return Int(raw)
        #else
        return nil
        #endif
    }

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
    /// Seeds the process-wide shared store with the given state's fixture. Exposed so
    /// unit tests can reuse the exact same seeding the app performs.
    static func seedSharedStore(_ state: UITestState) {
        seed(state, into: .shared)
    }

    /// Seeds an arbitrary store (e.g. a test scratch store) with the state's fixture.
    static func seed(_ state: UITestState, into store: ReadingListStore) {
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
