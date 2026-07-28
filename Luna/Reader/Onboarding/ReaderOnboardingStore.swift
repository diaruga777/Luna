//
//  ReaderOnboardingStore.swift
//  Luna
//

import Foundation

/// Per-install completion for Luna Reader's guided first-run experience.
///
/// This deliberately uses standard defaults, not the App Group: the three Luna
/// apps share their reading list and setup evidence, but each app owns its own
/// onboarding.  Only KindWiring+Reader consults this store.
final class ReaderOnboardingStore {
    static let shared = ReaderOnboardingStore()

    static let completionKey = "reader.onboarding.completed.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCompleted: Bool {
        defaults.bool(forKey: Self.completionKey)
    }

    func markCompleted() {
        defaults.set(true, forKey: Self.completionKey)
    }

    #if DEBUG
    func resetIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-resetReaderOnboarding") else { return }
        defaults.removeObject(forKey: Self.completionKey)
    }
    #endif
}
