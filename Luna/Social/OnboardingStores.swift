//
//  OnboardingStores.swift
//  Luna
//

import LunaMailAccount
import LunaStorage
import Foundation

/// The three per-surface stores `OnboardingFlow` reads/writes as it steps
/// through email, Safari, and Action Button setup — bundled so the flow can be
/// pointed at either the app's real, persisted state (`.real`) or a throwaway
/// overlay (`.ephemeral()`) used by Settings → "Replay Onboarding" so a replay
/// behaves exactly like a fresh install without ever mutating real state.
///
/// `OnboardingFlow` must only reach these stores through the accessor methods
/// below — never through the underlying singletons directly — so that a
/// `.ephemeral()` instance can transparently redirect every write.
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

    /// Non-nil only for `.ephemeral()` instances — the App-Group suite name to
    /// tear down when the replay finishes.
    private let scratchSuiteName: String?

    init(
        emailAccountStore: EmailAccountStore,
        safariStatusStore: SafariExtensionStatusStore,
        actionButtonStore: ActionButtonOnboardingStore,
        realSafariStatusStore: SafariExtensionStatusStore,
        baselineSafariEnabled: [String: Bool],
        scratchSuiteName: String?
    ) {
        self.emailAccountStore = emailAccountStore
        self.safariStatusStore = safariStatusStore
        self.actionButtonStoreValue = actionButtonStore
        self.realSafariStatusStore = realSafariStatusStore
        self.baselineSafariEnabled = baselineSafariEnabled
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
        scratchSuiteName: nil)

    // MARK: - Ephemeral (onboarding replay)

    /// A fresh throwaway overlay: a scratch `UserDefaults` suite (one is enough —
    /// each store's keys are already namespaced) backs the email account, Safari
    /// status, and Action Button stores, and the email credential is redirected
    /// to an in-memory stand-in. Nothing written through the returned instance
    /// ever reaches the real App Group or Keychain. Call `tearDown()` when the
    /// replay ends (success, skip, or the modal being dismissed any other way).
    public static func ephemeral() -> OnboardingStores {
        let suiteName = "onboarding.replay.\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: suiteName) ?? .standard
        let surface = AppSurfaceConfig.current.storageIdentifier
        let baseline = [surface: SafariExtensionStatusStore.shared.isEnabled(forSurface: surface)]
        return OnboardingStores(
            emailAccountStore: EmailAccountStore(defaults: scratch, credentialStorage: InMemoryCredentialStorage()),
            safariStatusStore: SafariExtensionStatusStore(defaults: scratch),
            actionButtonStore: ActionButtonOnboardingStore(defaults: scratch),
            realSafariStatusStore: .shared,
            baselineSafariEnabled: baseline,
            scratchSuiteName: suiteName)
    }

    /// Removes the scratch `UserDefaults` domain. No-op for `.real`. Safe to call
    /// more than once. Call this on every exit path of a replay — even if the app
    /// were killed mid-replay before this runs, the scratch suite is just an
    /// orphaned, never-read App-Group-less `UserDefaults` domain: real state was
    /// never touched.
    public func tearDown() {
        guard let scratchSuiteName else { return }
        UserDefaults.standard.removePersistentDomain(forName: scratchSuiteName)
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
