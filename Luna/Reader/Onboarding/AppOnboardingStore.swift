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
    /// Whether this device has a save lesson at all. Injected because it is
    /// hardware-derived: every simulator answers `.unavailable`.
    private let saveSetupMode: OnboardingSaveSetupMode
    /// When the newest save in the shared store was made. Injected so the
    /// save-completes-onboarding latch is assertable without writing the real
    /// App Group store.
    private let newestSaveDate: () -> Date?

    init(
        app: LunaApp = .current,
        defaults: UserDefaults = .standard,
        setupStatusStore: LunaSetupStatusStore? = nil,
        saveSetupMode: OnboardingSaveSetupMode = .current,
        newestSaveDate: @escaping () -> Date? = {
            ReadingListStore.shared.items().map(\.dateAdded).max()
        }
    ) {
        self.app = app
        self.defaults = defaults
        self.saveSetupMode = saveSetupMode
        self.setupStatusStore = setupStatusStore
            ?? (defaults === UserDefaults.standard
                ? .shared
                : LunaSetupStatusStore(defaults: defaults))
        self.newestSaveDate = newestSaveDate
    }

    var isCompleted: Bool {
        defaults.bool(forKey: completionKey)
            || setupStatusStore.centralAppCoversAllOnboarding(for: app)
            || (hasFinishedSafariSetup && hasFinishedSaveSetup)
    }

    func markCompleted() {
        defaults.set(true, forKey: completionKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// When this app's first-run journey began: its first launch, or the launch
    /// after an onboarding reset. Saves older than this belong to a previous
    /// journey (or to a sibling app's store) and do not answer it.
    var onboardingStartDate: Date? {
        defaults.object(forKey: onboardingStartKey) as? Date
    }

    /// Stamps the start of a journey when there is neither a completion nor a
    /// stamp yet. Called once per launch, before any root is constructed.
    func beginOnboardingIfNeeded(now: Date = Date()) {
        guard !isCompleted, onboardingStartDate == nil else { return }
        defaults.set(now, forKey: onboardingStartKey)
    }

    /// A save answers the first run, whatever made it: this app, a sibling, an
    /// extension, an intent, or the mailbox importer. The verdict is LATCHED
    /// into the completion marker rather than derived on every read, so
    /// deleting that save later cannot bring the first-run card back.
    ///
    /// Called at launch, so a save made mid-session settles the card's state
    /// for the next one — the util card deliberately keeps its layout for the
    /// remainder of the launch that saw the save.
    @discardableResult
    func markCompletedIfSavedSinceOnboardingStart() -> Bool {
        guard !isCompleted, let start = onboardingStartDate,
              let newest = newestSaveDate(), newest > start
        else { return false }
        markCompleted()
        return true
    }

    /// Whether the device-specific save-setup lesson has already been dealt
    /// with, either by completing it or explicitly skipping it. A real save can
    /// finish the overall onboarding before this lesson is visited, so this is
    /// intentionally separate from `isCompleted`.
    var hasHandledSaveSetup: Bool {
        defaults.bool(forKey: saveSetupHandledKey)
    }

    func markSaveSetupHandled(outcome: OnboardingSetupOutcome = .completed) {
        defaults.set(true, forKey: saveSetupHandledKey)
        if outcome == .skipped { defaults.set(true, forKey: saveSetupSkippedKey) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Whether the Safari lesson has been completed or explicitly skipped.
    /// Real extension evidence also counts, but this per-app marker preserves
    /// the user's choice when they skip the walkthrough.
    var hasHandledSafariSetup: Bool {
        defaults.bool(forKey: safariSetupHandledKey)
    }

    func markSafariSetupHandled(outcome: OnboardingSetupOutcome = .completed) {
        defaults.set(true, forKey: safariSetupHandledKey)
        if outcome == .skipped { defaults.set(true, forKey: safariSetupSkippedKey) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// A SKIPPED lesson is not a finished one as far as the util card is
    /// concerned: its button stays on the card, so the offer can be taken up
    /// later. Only genuinely completed buttons are retired.
    var wasSafariSetupSkipped: Bool {
        defaults.bool(forKey: safariSetupSkippedKey)
    }

    var wasSaveSetupSkipped: Bool {
        defaults.bool(forKey: saveSetupSkippedKey)
    }

    /// Whether the util card has stopped offering each lesson. A completed
    /// button keeps its checkmark for the rest of the session it was earned in
    /// and is retired the next time the app leaves the foreground — which is
    /// what makes room for the email nudge.
    var isSafariSetupButtonRetired: Bool {
        defaults.bool(forKey: safariSetupRetiredKey)
    }

    var isSaveSetupButtonRetired: Bool {
        defaults.bool(forKey: saveSetupRetiredKey)
    }

    /// Retires every leg that is genuinely done. Called at launch and on the way
    /// to the background, so a button earned in this session survives until the
    /// user looks away, and one earned in an earlier session is already gone.
    @discardableResult
    func retireCompletedSetupButtons() -> Bool {
        var retired = false
        if !isSafariSetupButtonRetired, hasFinishedSafariSetup, !wasSafariSetupSkipped {
            defaults.set(true, forKey: safariSetupRetiredKey)
            retired = true
        }
        if !isSaveSetupButtonRetired,
           saveSetupMode == .actionButtonShortcut,
           hasFinishedSaveSetup,
           !wasSaveSetupSkipped
        {
            defaults.set(true, forKey: saveSetupRetiredKey)
            retired = true
        }
        guard retired else { return false }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return true
    }

    var hasFinishedSafariSetup: Bool {
        hasHandledSafariSetup || setupStatusStore.safariRunApplies(to: app)
    }

    /// A device with no Action Button has no save lesson at all, so its save leg
    /// is finished by definition — nothing is offered, and nothing is owed.
    var hasFinishedSaveSetup: Bool {
        if hasHandledSaveSetup { return true }
        switch saveSetupMode {
        case .actionButtonShortcut:
            return setupStatusStore.shortcutRunApplies(to: app)
        case .unavailable:
            return true
        }
    }

    /// The diagnostics onboarding reset: the full first-run journey plays
    /// again on this app's next launch.
    func resetCompletion(now: Date = Date()) {
        for key in setupMarkerKeys { defaults.removeObject(forKey: key) }
        // A fresh journey starts here, so the saves already in the store are
        // not mistaken for its answer: the first-run card comes back on the
        // next launch and stays until a NEW save arrives.
        defaults.set(now, forKey: onboardingStartKey)
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

    private var safariSetupHandledKey: String {
        "\(app.storageIdentifier).onboarding.safariSetupHandled.v1"
    }

    private var saveSetupSkippedKey: String {
        "\(app.storageIdentifier).onboarding.saveSetupSkipped.v1"
    }

    private var safariSetupSkippedKey: String {
        "\(app.storageIdentifier).onboarding.safariSetupSkipped.v1"
    }

    private var saveSetupRetiredKey: String {
        "\(app.storageIdentifier).onboarding.saveSetupRetired.v1"
    }

    private var safariSetupRetiredKey: String {
        "\(app.storageIdentifier).onboarding.safariSetupRetired.v1"
    }

    /// Every marker a reset takes back out, so the next launch replays the whole
    /// first run: completion, both handled legs, how each was handled, and
    /// whether the card has stopped offering them.
    private var setupMarkerKeys: [String] {
        [
            completionKey,
            saveSetupHandledKey,
            safariSetupHandledKey,
            saveSetupSkippedKey,
            safariSetupSkippedKey,
            saveSetupRetiredKey,
            safariSetupRetiredKey,
        ]
    }

    private var onboardingStartKey: String {
        "\(app.storageIdentifier).onboarding.startedAt.v1"
    }

    #if DEBUG
    func resetIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-resetOnboarding")
                || (app == .reader && arguments.contains("-resetReaderOnboarding"))
        else { return }
        for key in setupMarkerKeys { defaults.removeObject(forKey: key) }
        defaults.set(Date(), forKey: onboardingStartKey)
        setupStatusStore.resetAllRunEvidence()
    }
    #endif
}
