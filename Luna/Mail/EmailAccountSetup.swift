//
//  EmailAccountSetup.swift
//  Luna
//
//  Step 1 of connecting an email account, minus the UI that collects the address:
//  infer the provider, resolve IMAP/SMTP settings, then either push the
//  app-specific-password screen (`CredentialViewController`) or run Outlook OAuth
//  to completion. Owned by whatever screen holds the address field — today the
//  inline field in Settings → Email. See `claudedocs/email-login.md`.
//

import LunaMailAccount
import LunaMailTransport
import LunaSocial
import AuthenticationServices
import UIKit
import LunaModels

@MainActor
final class EmailAccountSetup {

    private weak var presenter: UIViewController?
    private let accountStore: EmailAccountStore
    private let onBusyChange: (Bool) -> Void
    private let completion: (Bool) -> Void

    /// Latched while autodiscovery runs: the caller's Connect row and return key
    /// stay live during the (network) resolve, and repeated taps would push
    /// several credential screens onto the stack.
    private var isResolving = false
    private var authSession: ASWebAuthenticationSession?
    private var contextProvider: AuthPresentationContext?
    private var loadingCover: EmailLoginLoadingCover?

    /// `onBusyChange` brackets the one network wait on this step so the caller can
    /// show it (and refuse further taps). `completion(true)` means an account was
    /// connected and saved; `false` means the attempt ended without one.
    init(
        presenter: UIViewController,
        accountStore: EmailAccountStore = .shared,
        onBusyChange: @escaping (Bool) -> Void = { _ in },
        completion: @escaping (Bool) -> Void
    ) {
        self.presenter = presenter
        self.accountStore = accountStore
        self.onBusyChange = onBusyChange
        self.completion = completion
    }

    /// The existing lightweight validation: no full RFC 5322 parse, just a shape
    /// check good enough to catch obvious typos before a network round trip.
    static func isValidAddress(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    /// Begins setup for `rawAddress`. Returns false (doing nothing) when the
    /// address doesn't look like one or a resolve is already in flight — the
    /// caller signals that itself (a shake, usually).
    @discardableResult
    func start(address rawAddress: String) -> Bool {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !isResolving, Self.isValidAddress(address) else { return false }
        let providerID = ProviderInference.inferProviderID(for: address)

        if providerID == .outlook {
            startOutlookOAuth(address: address)
            return true
        }
        // App-password providers (and generic, resolved below).
        isResolving = true
        onBusyChange(true)
        Task { @MainActor in
            defer {
                isResolving = false
                onBusyChange(false)
            }
            let server = await resolveServer(providerID: providerID, address: address)
            guard let presenter, let nav = presenter.navigationController,
                  nav.topViewController === presenter
            else {
                // The user navigated away while autodiscovery was in flight —
                // don't push a credential screen over wherever they went.
                completion(false)
                return
            }
            let account = EmailAccount(
                providerID: providerID, address: address, displayName: nil, server: server)
            nav.pushViewController(
                CredentialViewController(
                    account: account,
                    accountStore: accountStore,
                    completion: { [weak self] connected in self?.completion(connected) }),
                animated: true)
        }
        return true
    }

    /// Resolves IMAP/SMTP settings: the registry entry for known providers, or
    /// ISPDB autodiscovery (falling back to Gmail-like defaults) for custom domains.
    private func resolveServer(
        providerID: MailProvider.ID, address: String
    ) async -> MailServerConfig {
        if let server = MailProvider.provider(for: providerID).server { return server }
        if let domain = ProviderInference.domain(of: address),
           let discovered = await ProviderInference.autodiscover(domain: domain) {
            return discovered.server
        }
        // Unknown custom domain: a reasonable implicit-TLS default the user can't
        // easily correct here, but most providers accept it.
        let host = ProviderInference.domain(of: address) ?? "mail"
        return MailServerConfig(
            imapHost: "imap.\(host)", smtpHost: "smtp.\(host)", smtpPort: 465, smtpUsesSTARTTLS: false)
    }

    // MARK: - Outlook OAuth

    private func startOutlookOAuth(address: String) {
        guard let presenter else { return }
        let clientID = MicrosoftOAuth.clientID
        guard !clientID.isEmpty else {
            presentError(L10n.string("Outlook isn't configured in this build."))
            return
        }
        let pkce = MicrosoftOAuth.makePKCE()
        guard let url = MicrosoftOAuth.authorizationURL(
            clientID: clientID, challenge: pkce.challenge, loginHint: address)
        else { presentError(L10n.string("Couldn't start Outlook sign-in.")); return }

        let context = AuthPresentationContext(anchor: presenter.view.window)
        contextProvider = context
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: MicrosoftOAuth.redirectScheme
        ) { [weak self] callback, error in
            // ASWebAuthenticationSession doesn't document which thread delivers
            // this handler; everything below touches UIKit, so hop to the main
            // actor before doing anything.
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        // The user backed out of the web sheet — leave the screen
                        // usable, no error, no cover.
                        self.completion(false)
                        return
                    }
                    self.presentError(L10n.string("Outlook sign-in failed. Please try again."))
                    return
                }
                guard let callback,
                      let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    // A callback without a `code` item is a real failure, not a
                    // cancellation — it must not fail silently.
                    self.presentError(L10n.string("Outlook sign-in failed. Please try again."))
                    return
                }
                // The webview is gone but the token exchange + inbox-filter setup
                // still run. Cover the host screen with a full-screen dot-matrix
                // spinner so nothing is tappable meanwhile.
                guard let host = self.presenter else { return }
                host.view.endEditing(true)
                let cover = EmailLoginLoadingCover(
                    host: host.navigationController?.view ?? host.view)
                self.loadingCover = cover
                await self.exchangeOutlookCode(
                    code, verifier: pkce.verifier, clientID: clientID, address: address, cover: cover)
            }
        }
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    private func exchangeOutlookCode(
        _ code: String, verifier: String, clientID: String, address: String,
        cover: EmailLoginLoadingCover
    ) async {
        do {
            var request = URLRequest(url: URL(string: MicrosoftOAuth.tokenEndpoint)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = MicrosoftOAuth.formEncode(
                MicrosoftOAuth.tokenExchangeParameters(clientID: clientID, code: code, verifier: verifier))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "outlook", code: 1)
            }
            struct Wire: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double }
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            let tokens = OAuthTokens(
                accessToken: wire.access_token, refreshToken: wire.refresh_token ?? "",
                expiry: Date().addingTimeInterval(wire.expires_in))
            let account = EmailAccount(providerID: .outlook, address: address, displayName: nil, server: nil)
            accountStore.save(account, credential: .oauth(tokens))
            // Best-effort: install the inbox filter.
            if let transport = MailTransportFactory.make() {
                _ = try? await transport.createLunaFilter()
            }
            cover.resolveToCheckmark { [weak self] in
                cover.hide()
                self?.loadingCover = nil
                self?.completion(true)
            }
        } catch {
            cover.hide()
            loadingCover = nil
            presentError(L10n.string("Outlook sign-in failed. Please try again."))
        }
    }

    private func presentError(_ message: String) {
        completion(false)
        let alert = UIAlertController(title: L10n.string("Sign-in failed"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
        presenter?.present(alert, animated: true)
    }
}
