//
//  AppOnboardingStore.swift
//  Luna
//

import LunaModels
import LunaStorage
import Foundation

/// Per-install completion and exact temporary-save ownership for each Luna app.
///
/// This deliberately uses standard defaults, not the App Group: all Luna apps
/// share their content stores and setup evidence, but each host owns its own
/// onboarding and must only remove the demonstration item it created.
final class AppOnboardingStore {
    static let shared = AppOnboardingStore(app: .current)
    static let didChange = Notification.Name("AppOnboardingStoreDidChange")

    let app: LunaApp

    private let defaults: UserDefaults
    private let setupStatusStore: LunaSetupStatusStore

    init(
        app: LunaApp = .current,
        defaults: UserDefaults = .standard,
        setupStatusStore: LunaSetupStatusStore? = nil
    ) {
        self.app = app
        self.defaults = defaults
        self.setupStatusStore = setupStatusStore
            ?? (defaults === UserDefaults.standard
                ? .shared
                : LunaSetupStatusStore(defaults: defaults))
    }

    var isCompleted: Bool {
        defaults.bool(forKey: completionKey)
            || setupStatusStore.centralAppCoversAllOnboarding(for: app)
    }

    func markCompleted() {
        defaults.set(true, forKey: completionKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Whether the device-specific save-setup lesson has already been dealt
    /// with, either by completing it or explicitly skipping it. A real save can
    /// finish the overall onboarding before this lesson is visited, so this is
    /// intentionally separate from `isCompleted`.
    var hasHandledSaveSetup: Bool {
        defaults.bool(forKey: saveSetupHandledKey)
    }

    func markSaveSetupHandled() {
        defaults.set(true, forKey: saveSetupHandledKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The diagnostics onboarding reset: the full first-run journey plays
    /// again on this app's next launch.
    func resetCompletion() {
        defaults.removeObject(forKey: completionKey)
        defaults.removeObject(forKey: saveSetupHandledKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
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

    private var saveSetupHandledKey: String {
        "\(app.storageIdentifier).onboarding.saveSetupHandled.v1"
    }

    #if DEBUG
    func resetIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-resetOnboarding")
                || (app == .reader && arguments.contains("-resetReaderOnboarding"))
        else { return }
        defaults.removeObject(forKey: completionKey)
        defaults.removeObject(forKey: saveSetupHandledKey)
    }
    #endif
}
