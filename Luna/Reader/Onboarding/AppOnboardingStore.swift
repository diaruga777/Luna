//
//  AppOnboardingStore.swift
//  Luna
//

import LunaModels
import LunaStorage
import LunaAppConfig
import Foundation

/// When the newest save in the shared store was made — the one reading the
/// save-completes-onboarding latch needs.
///
/// Injected so the latch is assertable without writing the real App Group store,
/// and so a staged launch can hand over fixture dates.
protocol OnboardingNewestSaveProviding {
    /// `excludedID` is onboarding's own demonstration row, which must never
    /// count as the user's first save.
    func newestSaveDate(excluding excludedID: UUID?) -> Date?
}

/// The production answer: the shared saves list.
struct SharedStoreNewestSave: OnboardingNewestSaveProviding {
    func newestSaveDate(excluding excludedID: UUID?) -> Date? {
        SavesStore.shared.items()
            .filter { $0.id != excludedID }
            .map(\.dateAdded).max()
    }
}

/// Per-install completion and exact temporary-save ownership for each Luna app.
///
/// This deliberately uses standard defaults, not the App Group: all Luna apps
/// share their content stores and setup evidence, but each host owns its own
/// onboarding and must only remove the demonstration item it created.
final class AppOnboardingStore {
    // Standard defaults, or a staged run's stand-in for them
    // (`claudedocs/staging.md`): onboarding is the one thing a stage most needs
    // to control and the one store the App-Group redirect deliberately misses.
    static let shared = AppOnboardingStore(
        app: .current, defaults: StageContainer.standardDefaults())
    static let didChange = Notification.Name("AppOnboardingStoreDidChange")

    let app: LunaApp

    private let defaults: UserDefaults
    private let setupStatusStore: LunaSetupStatusStore
    /// Which save lesson this device gets. Injected because it is
    /// hardware-derived, so a test can pin either answer.
    private let saveSetupMode: OnboardingSaveSetupMode
    /// When the newest save in the shared store was made, ignoring one id.
    /// Injected so the save-completes-onboarding latch is assertable without
    /// writing the real App Group store.
    private let newestSave: any OnboardingNewestSaveProviding

    init(
        app: LunaApp = .current,
        defaults: UserDefaults = .standard,
        setupStatusStore: LunaSetupStatusStore? = nil,
        saveSetupMode: OnboardingSaveSetupMode = .current,
        newestSave: any OnboardingNewestSaveProviding = SharedStoreNewestSave()
    ) {
        self.app = app
        self.defaults = defaults
        self.saveSetupMode = saveSetupMode
        self.setupStatusStore = setupStatusStore
            ?? (defaults === UserDefaults.standard
                ? .shared
                : LunaSetupStatusStore(defaults: defaults))
        self.newestSave = newestSave
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
    /// The ONE save that does not answer it is the lesson's own: the save
    /// demonstration runs the real share surface, so it really does write a real
    /// row, and letting the app complete its own first run on the strength of a
    /// rehearsal it played to itself would be a lie. It is marked as the temporary
    /// save while it exists (`temporarySaveIdentifier`) and deleted immediately
    /// after each pass; this exclusion covers the case where a launch lands in
    /// between.
    @discardableResult
    func markCompletedIfSavedSinceOnboardingStart() -> Bool {
        guard !isCompleted, let start = onboardingStartDate,
              let newest = newestSave.newestSaveDate(excluding: temporarySaveIdentifier),
              newest > start
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
        if !isSaveSetupButtonRetired, hasFinishedSaveSetup, !wasSaveSetupSkipped {
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

    /// Takes the first-run journey back to its start, so the whole thing plays
    /// again on this app's next launch. The Diagnostics screen's reset button
    /// erases the install outright (`FactoryReset`), which reaches these
    /// markers by deleting the domain they live in. The `-resetOnboarding`
    /// launch flag is the only other caller.
    func resetCompletion(now: Date = Date()) {
        for key in setupMarkerKeys { defaults.removeObject(forKey: key) }
        // A fresh journey starts here, so the saves already in the store are
        // not mistaken for its answer: the first-run card comes back on the
        // next launch and stays until a NEW save arrives.
        defaults.set(now, forKey: onboardingStartKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The row the save lesson's rehearsal currently owns, if one exists right
    /// now. Two readers: the launch sweep that removes an item an OLDER build
    /// left behind (`BundledLunaArticle.cleanupLegacyTemporarySave`), and the
    /// first-run latch, which must not count this app's own rehearsal as the
    /// user's first save.
    var temporarySaveIdentifier: UUID? {
        defaults.string(forKey: temporarySaveKey).flatMap(UUID.init(uuidString:))
    }

    /// Claims a row as the save lesson's own. The lesson runs the REAL share
    /// surface — which really does append — so between the append and the
    /// deletion that follows each demonstration pass there is a row in the store
    /// that nobody asked for, and this is what names it.
    func recordTemporarySave(identifier: UUID) {
        defaults.set(identifier.uuidString, forKey: temporarySaveKey)
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
        resetCompletion()
        setupStatusStore.resetAllRunEvidence()
    }
    #endif
}
