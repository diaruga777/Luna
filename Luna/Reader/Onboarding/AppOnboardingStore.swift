//
//  AppOnboardingStore.swift
//  Luna
//

import LunaModels
import Foundation

/// Per-install completion and exact temporary-save ownership for each Luna app.
///
/// This deliberately uses standard defaults, not the App Group: all Luna apps
/// share their content stores and setup evidence, but each host owns its own
/// onboarding and must only remove the demonstration item it created.
final class AppOnboardingStore {
    static let shared = AppOnboardingStore(app: .current)

    let app: LunaApp

    private let defaults: UserDefaults

    init(app: LunaApp = .current, defaults: UserDefaults = .standard) {
        self.app = app
        self.defaults = defaults
    }

    var isCompleted: Bool {
        defaults.bool(forKey: completionKey)
    }

    func markCompleted() {
        defaults.set(true, forKey: completionKey)
    }

    /// The diagnostics onboarding reset: the full first-run journey plays
    /// again on this app's next launch.
    func resetCompletion() {
        defaults.removeObject(forKey: completionKey)
    }

    /// The demonstration item an OLDER build installed into the shared store.
    /// Nothing records one any more — onboarding writes nothing — so this is
    /// read only by the launch sweep that takes such an item back out
    /// (`OnboardingLegacyDemoSave`).
    var temporarySaveIdentifier: UUID? {
        defaults.string(forKey: temporarySaveKey).flatMap(UUID.init(uuidString:))
    }

    #if DEBUG
    /// Writes the marker an older build would have left, so the launch sweep
    /// can be tested. Nothing in the app records one.
    func recordLegacyTemporarySaveForTesting(identifier: UUID) {
        defaults.set(identifier.uuidString, forKey: temporarySaveKey)
    }
    #endif

    func clearTemporarySaveIdentifier() {
        defaults.removeObject(forKey: temporarySaveKey)
    }

    private var completionKey: String {
        // Preserve Reader's shipped key so completed users do not re-onboard.
        app == .reader
            ? "reader.onboarding.completed.v1"
            : "\(app.storageIdentifier).onboarding.completed.v1"
    }

    private var temporarySaveKey: String {
        "\(app.storageIdentifier).onboarding.temporarySave.v1"
    }

    #if DEBUG
    func resetIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-resetOnboarding")
                || (app == .reader && arguments.contains("-resetReaderOnboarding"))
        else { return }
        defaults.removeObject(forKey: completionKey)
    }
    #endif
}
