//
//  ReaderOnboardingStore.swift
//  Luna
//

import LunaModels
import Foundation

/// Per-install completion and exact temporary-save ownership for each Luna app.
///
/// This deliberately uses standard defaults, not the App Group: all Luna apps
/// share their content stores and setup evidence, but each host owns its own
/// onboarding and must only remove the demonstration item it created.
final class ReaderOnboardingStore {
    static var shared: ReaderOnboardingStore {
        ReaderOnboardingStore(app: .current)
    }

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

    var temporarySaveIdentifier: UUID? {
        defaults.string(forKey: temporarySaveKey).flatMap(UUID.init(uuidString:))
    }

    func recordTemporarySave(identifier: UUID) {
        defaults.set(identifier.uuidString, forKey: temporarySaveKey)
    }

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
