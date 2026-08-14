//
//  StageCatalog+Email.swift
//  Luna
//
//  Stages for the email capability: connecting an account, sending saves to
//  contacts, and the screens that hang off both. Compiled only into the two
//  apps that have it (`LunaApp.sharesByEmail` — Luna and LunaReader), which is
//  the same pair as the article kind but for an unrelated reason: Downloader
//  and Price Tracker share by plain URL through the system share sheet and
//  connect no account at all (`claudedocs/social-sharing.md`).
//
//  Separate from `StageCatalog+Article.swift` on purpose. The two app sets
//  coincide today; the reasons do not, and an app could gain articles without
//  gaining a mailbox.
//

#if DEBUG

import LunaMailAccount
import LunaModels
import LunaSocialUI
import UIKit

enum EmailStageCatalog {

    @MainActor
    static func install() {
        StageRegistry.register(accountStages + contactStages)
    }

    // MARK: - The sending account

    @MainActor
    private static var accountStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "settings.email.signed-out", screen: "Settings → Email & Sending",
                variant: "signed out",
                summary: "No account: the Sharing Account section IS the sign-in form "
                    + "(`claudedocs/email-login.md`).",
                kind: .email,
                make: { emailScreen(state: .signedOut) }),
            StageDescriptor(
                id: "settings.email.connecting", screen: "Settings → Email & Sending",
                variant: "connecting",
                summary: "A sign-in attempt in flight — the spinner in the Connect row. "
                    + "Frozen: staged mode holds the busy flag rather than running a login.",
                kind: .email,
                make: { emailScreen(state: .connecting) }),
            StageDescriptor(
                id: "settings.email.connected", screen: "Settings → Email & Sending",
                variant: "connected",
                summary: "An account in good standing: address, inbox filter, sign out.",
                kind: .email,
                make: { emailScreen(state: .connected) }),
            StageDescriptor(
                id: "settings.email.error", screen: "Settings → Email & Sending",
                variant: "credentials rejected",
                summary: "The account the provider stopped accepting: the issue row, the "
                    + "reconnect affordance, and the 'sign in required' detail.",
                kind: .email,
                make: { emailScreen(state: .rejected) }),
            StageDescriptor(
                id: "settings.email.expired", screen: "Settings → Email & Sending",
                variant: "authorization expired",
                summary: "The OAuth variant of the same recovery — an Outlook grant that "
                    + "aged out rather than a password that was refused.",
                kind: .email,
                make: { emailScreen(state: .expired) }),
            StageDescriptor(
                id: "settings.kindle", screen: "Settings → Kindle", variant: "connected",
                summary: "Send-to-Kindle, reachable only once an account exists.",
                kind: .email,
                seed: { _ = sharedConnectedAccount() },
                make: { UINavigationController(rootViewController: KindleSettingsScreen()) }),
            StageDescriptor(
                id: "settings.auto-send", screen: "Settings → Auto-send by source",
                variant: "Kindle",
                summary: "Which capture sources forward automatically to a destination.",
                kind: .email,
                make: {
                    UINavigationController(rootViewController: AutoSendBySourceScreen(
                        destinationID: ArticleDestinationID.kindle,
                        destinationName: L10n.string("Common_kindle")))
                }),
        ]
    }

    private enum AccountState { case signedOut, connecting, connected, rejected, expired }

    @MainActor
    private static func emailScreen(state: AccountState) -> UIViewController {
        let suite = "LunaStage.email.\(state)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        // An in-memory credential store, so a staged sign-in never reaches the
        // App Group Keychain — the one piece of state the throwaway container
        // does not cover.
        let store = EmailAccountStore(
            defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        switch state {
        case .signedOut, .connecting:
            break
        case .connected, .rejected:
            store.save(
                EmailAccount(providerID: .gmail, address: "reader@example.com"),
                credential: .appPassword("fixture-password"))
        case .expired:
            store.save(
                EmailAccount(providerID: .outlook, address: "reader@outlook.com"),
                credential: .appPassword("fixture-password"))
        }
        if state == .rejected { store.markAuthenticationIssue(.credentialsRejected) }
        if state == .expired { store.markAuthenticationIssue(.authorizationExpired) }

        let screen = EmailAndKindleSettingsScreen(accountStore: store)
        if state == .connecting { screen.setConnectingForStaging(true) }
        return UINavigationController(rootViewController: screen)
    }

    /// Connects the SHARED account store, for the stages whose screen reads
    /// `.shared` rather than an injected one. Safe because a staged run's
    /// defaults suite is a throwaway; the credential still goes to memory only.
    @MainActor
    @discardableResult
    private static func sharedConnectedAccount() -> EmailAccountStore {
        let store = EmailAccountStore.shared
        store.save(
            EmailAccount(providerID: .gmail, address: "reader@example.com"),
            credential: .appPassword("fixture-password"))
        return store
    }

    // MARK: - Contacts and sharing

    @MainActor
    private static var contactStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "social.contacts", screen: "Contacts", variant: "empty",
                summary: "The Contacts list on a device with no contacts yet — its own "
                    + "identity QR and the invite affordance.",
                kind: .email,
                make: { UINavigationController(rootViewController: FriendsViewController()) }),
            StageDescriptor(
                id: "social.recipient-picker", screen: "Recipient picker", variant: "empty",
                summary: "What 'send this save to someone' opens, before any contact exists.",
                kind: .email,
                make: {
                    UINavigationController(
                        rootViewController: RecipientPickerViewController(onComplete: { _ in }))
                }),
        ]
    }
}

#endif
