//
//  OnboardingDemoSaveEvictor.swift
//  Luna
//

import Foundation

/// Takes the onboarding demonstration save back out the moment the user makes a
/// real one.
///
/// The mock article/video/tracker is never content the user asked for: it exists
/// so the deck that replaces the onboarding journey isn't an empty screen. The
/// launch and background cleanups already keep it from becoming permanent; this
/// closes the window in between, where the user saves something from inside the
/// app and would otherwise sit with their first real card next to a fake one.
///
/// The watch is deliberately id-based rather than count-based: an app can be
/// re-onboarded with real saves already in the store (diagnostics resets it),
/// and only an id that was NOT there when the demonstration ended is a new save.
@MainActor
final class OnboardingDemoSaveEvictor {
    static let shared = OnboardingDemoSaveEvictor()

    private var save: OnboardingTemporarySave?
    private var registry = AppOnboardingStore.shared
    private var center = NotificationCenter.default
    private var knownIdentifiers: Set<UUID> = []
    private var observers: [NSObjectProtocol] = []

    var isArmed: Bool { save != nil }

    init() {}

    /// Begins watching this app's stores. A no-op unless onboarding actually
    /// owns a demonstration item right now, so an app whose user already had
    /// this exact content (or whose install failed) never observes anything.
    func arm(
        _ save: OnboardingTemporarySave,
        registry: AppOnboardingStore = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        disarm()
        guard registry.temporarySaveIdentifier != nil else { return }
        self.save = save
        self.registry = registry
        center = notificationCenter
        knownIdentifiers = save.storedIdentifiers()
        observers = save.changeNotifications.map { name in
            notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.contentDidChange() }
            }
        }
    }

    func disarm() {
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
        save = nil
        knownIdentifiers = []
    }

    /// One evaluation of the armed watch. The notifications drive this in the
    /// app; tests call it directly because a main-queue block observer runs a
    /// turn of the run loop later than the store mutation that posted it.
    func contentDidChange() {
        guard let save, let temporary = registry.temporarySaveIdentifier else {
            disarm()
            return
        }
        let current = save.storedIdentifiers()
        // The demonstration item leaving on its own — a swipe-delete, the
        // background cleanup — is the end of the watch, not a save to react to.
        guard current.contains(temporary) else {
            disarm()
            return
        }
        guard !current.subtracting(knownIdentifiers).isEmpty else { return }
        // Disarm FIRST: the cleanup deletes an item, which posts the very
        // notification that brought us here.
        disarm()
        save.cleanup()
    }
}
