//
//  OnboardingStores.swift
//  Luna
//

import LunaMailAccount
import LunaStorage
import Foundation

/// The three per-surface stores `OnboardingFlow` reads/writes as it steps
/// through email, Safari, and Action Button setup — bundled so the flow can be
/// pointed at either the app's real, persisted state (`.real`) or a replay
/// overlay (`.ephemeral()`) used by Settings → "Replay Onboarding" so a replay
/// behaves like a fresh install.
///
/// `OnboardingFlow` must only reach these stores through the accessor methods
/// below — never through the underlying singletons directly — so that a
/// `.ephemeral()` instance can transparently redirect replay-only writes. Action
/// Button is the exception: it temporarily re-arms the real shared state machine
/// so lifecycle callbacks and App Intents can participate, then restores the
/// user's previous state in `tearDown()`.
public final class OnboardingStores {

    public let emailAccountStore: EmailAccountStore

    /// Where the flow's own reads/writes land: the real shared store for
    /// `.real`, or a scratch overlay for `.ephemeral()`.
    private let safariStatusStore: SafariExtensionStatusStore
    private let actionButtonStoreValue: ActionButtonOnboardingStore

    /// Always the actual App-Group-backed store, even on an ephemeral instance —
    /// needed for the Safari read-through rule below.
    private let realSafariStatusStore: SafariExtensionStatusStore

    /// Per-surface snapshot of `realSafariStatusStore.isEnabled(forSurface:)`
    /// taken when this instance was created. Empty (and unused) for `.real`.
    private let baselineSafariEnabled: [String: Bool]

    /// Non-empty only for `.ephemeral()` replay instances. Action Button setup is
    /// intentionally replayed through the real App-Group state machine so
    /// AppDelegate lifecycle callbacks and App Intents can drive it; these states
    /// let `tearDown()` put the user's real persisted state back afterward.
    private let actionButtonRestoreStates: [String: ActionButtonOnboardingState]

    /// Non-nil only for `.ephemeral()` instances — the App-Group suite name to
    /// tear down when the replay finishes.
    private let scratchSuiteName: String?

    init(
        emailAccountStore: EmailAccountStore,
        safariStatusStore: SafariExtensionStatusStore,
        actionButtonStore: ActionButtonOnboardingStore,
        realSafariStatusStore: SafariExtensionStatusStore,
        baselineSafariEnabled: [String: Bool],
        actionButtonRestoreStates: [String: ActionButtonOnboardingState],
        scratchSuiteName: String?
    ) {
        self.emailAccountStore = emailAccountStore
        self.safariStatusStore = safariStatusStore
        self.actionButtonStoreValue = actionButtonStore
        self.realSafariStatusStore = realSafariStatusStore
        self.baselineSafariEnabled = baselineSafariEnabled
        self.actionButtonRestoreStates = actionButtonRestoreStates
        self.scratchSuiteName = scratchSuiteName
    }

    // MARK: - Real (production default)

    /// The app's real, persisted stores — identical behavior to reaching the
    /// three `.shared` singletons directly.
    public static let real = OnboardingStores(
        emailAccountStore: .shared,
        safariStatusStore: .shared,
        actionButtonStore: .shared,
        realSafariStatusStore: .shared,
        baselineSafariEnabled: [:],
        actionButtonRestoreStates: [:],
        scratchSuiteName: nil)

    // MARK: - Ephemeral (onboarding replay)

    /// A fresh replay overlay: a scratch `UserDefaults` suite (one is enough —
    /// each store's keys are already namespaced) backs the email account and
    /// Safari status, and the email credential is redirected to an in-memory
    /// stand-in. Action Button setup is temporarily reset in the real App Group
    /// state machine so AppDelegate and App Intent callbacks can drive the
    /// replay. Call `tearDown()` when the replay ends (success, skip, or the
    /// modal being dismissed any other way) to restore that real state.
    public static func ephemeral() -> OnboardingStores {
        let suiteName = "onboarding.replay.\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: suiteName) ?? .standard
        let surface = AppSurfaceConfig.current.storageIdentifier
        let baseline = [surface: SafariExtensionStatusStore.shared.isEnabled(forSurface: surface)]
        let actionButtonStore = ActionButtonOnboardingStore.shared
        let actionButtonRestoreStates = [surface: actionButtonStore.state(forSurface: surface)]
        actionButtonStore.setState(.notStarted, forSurface: surface)
        return OnboardingStores(
            emailAccountStore: EmailAccountStore(defaults: scratch, credentialStorage: InMemoryCredentialStorage()),
            safariStatusStore: SafariExtensionStatusStore(defaults: scratch),
            actionButtonStore: actionButtonStore,
            realSafariStatusStore: .shared,
            baselineSafariEnabled: baseline,
            actionButtonRestoreStates: actionButtonRestoreStates,
            scratchSuiteName: suiteName)
    }

    /// Restores any temporarily re-armed Action Button state, then removes the
    /// scratch `UserDefaults` domain. No-op for `.real`. Safe to call more than
    /// once. Call this on every exit path of a replay.
    public func tearDown() {
        for (surface, state) in actionButtonRestoreStates {
            actionButtonStoreValue.setState(state, forSurface: surface)
        }
        if let scratchSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: scratchSuiteName)
        }
    }

    // MARK: - Safari extension status

    /// Read-through rule for replay: reports enabled once the scratch overlay
    /// itself has been marked enabled, OR once the REAL enablement — which is
    /// written by the Safari extension's own process and can legitimately change
    /// at any time, including mid-replay — newly flips true relative to the
    /// baseline snapshot taken when this instance was created. That means a
    /// replay always starts looking "not yet enabled" like a fresh install, but a
    /// user who genuinely turns the extension on partway through the replay still
    /// advances the flow, exactly as a first-time user would. For `.real` this
    /// collapses to a direct passthrough.
    public func isSafariExtensionEnabled(forSurface surface: String) -> Bool {
        guard scratchSuiteName != nil else {
            return safariStatusStore.isEnabled(forSurface: surface)
        }
        if safariStatusStore.isEnabled(forSurface: surface) { return true }
        let baselineWasEnabled = baselineSafariEnabled[surface] ?? false
        return realSafariStatusStore.isEnabled(forSurface: surface) && !baselineWasEnabled
    }

    /// Whether the Safari onboarding step should continue into the iOS 27 Action
    /// Button setup path. Replays start with Safari enablement visually "reset",
    /// but if the extension was already enabled before replay began, the user
    /// should still be able to experience the shortcut/action-button steps again.
    public func shouldUseActionButtonFlowAfterSafari(forSurface surface: String) -> Bool {
        if isSafariExtensionEnabled(forSurface: surface) { return true }
        guard scratchSuiteName != nil else { return false }
        return baselineSafariEnabled[surface] == true
    }

    public func setSafariTakeoverPending(_ pending: Bool, forSurface surface: String) {
        safariStatusStore.setTakeoverPending(pending, forSurface: surface)
    }

    // MARK: - Action Button state machine

    public func actionButtonState(forSurface surface: String) -> ActionButtonOnboardingState {
        actionButtonStoreValue.state(forSurface: surface)
    }

    public func setActionButtonState(_ state: ActionButtonOnboardingState, forSurface surface: String) {
        actionButtonStoreValue.setState(state, forSurface: surface)
    }

    public func beginActionButtonInstallStep(forSurface surface: String) {
        actionButtonStoreValue.beginInstallStep(forSurface: surface)
    }

    public func markActionButtonSettingsDeeplinkTapped(forSurface surface: String) {
        actionButtonStoreValue.markSettingsDeeplinkTapped(forSurface: surface)
    }
}
