//
//  EmailLoginFlow.swift
//  Luna
//

import LunaMailAccount
import LunaMailTransport
import LunaDesignSystem
import LunaSocial
import AuthenticationServices
import LunaTransitions
import UIKit

/// The email-account sign-in flow: enter an address → infer the provider →
/// either paste an app-specific password (Gmail/iCloud/Yahoo/custom) or run
/// OAuth (Outlook). Verifies before saving. See `claudedocs/email-login.md` for
/// the end-to-end design (autodiscovery, the loading cover, the notification-
/// permission timing, the checkmark success beat, the AutoFill invariants).
public enum EmailLoginFlow {

    /// Presents the flow modally. `completion(true)` when an account was connected.
    /// `accountStore` defaults to the real shared store; onboarding replay passes
    /// its ephemeral overlay so a "sign in" during a replay never persists.
    public static func present(
        from presenter: UIViewController, accountStore: EmailAccountStore = .shared,
        completion: ((Bool) -> Void)? = nil
    ) {
        let entry = EmailEntryViewController(accountStore: accountStore, completion: completion)
        let nav = UINavigationController(rootViewController: entry)
        nav.modalPresentationStyle = .formSheet
        nav.installDotMatrixTransitions()
        DotMatrixModal.present(nav, from: presenter)
    }
}

// MARK: - Step 1: email address

final class EmailEntryViewController: UIViewController {

    private let accountStore: EmailAccountStore
    private let completion: ((Bool) -> Void)?
    private let field = UITextField()
    private let providerBadge = ProviderBadgeView()
    private let continueButton = EmailLoginActionButton(title: "Continue")

    init(accountStore: EmailAccountStore, completion: ((Bool) -> Void)?) {
        self.accountStore = accountStore
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // The hero owns the title; the nav bar just carries Cancel.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))

        let hero = EmailLoginUI.heroTile(symbol: "envelope.badge")
        let titleLabel = EmailLoginUI.titleLabel("Connect your email")
        let bodyLabel = EmailLoginUI.bodyLabel(
            "Luna sends and reads shared articles through your own email account.")

        field.placeholder = "you@example.com"
        field.font = .preferredFont(forTextStyle: .body)
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        // Prefer the system's fast personal-email suggestion over the credential
        // manager UI. AutoFill insertion still stays native because this field has
        // no delegate and starts its input session only after presentation.
        field.textContentType = .emailAddress
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.contentVerticalAlignment = .center
        field.returnKeyType = .continue
        field.translatesAutoresizingMaskIntoConstraints = false
        // Keep the text field delegate nil. In particular, don't interpose on the
        // iOS 26 input-suggestion/replacement path used by system and third-party
        // credential providers. The return key needs only a control action.
        field.addTarget(self, action: #selector(continueTapped), for: .editingDidEndOnExit)
        // Capture the value as it changes so keyboard AutoFill and password-manager
        // fills — which arrive through the editing-change path (and can drop the
        // field's own `text` when their extension UI backgrounds the app) — stick
        // even though we only read the address lazily when Continue is tapped.
        field.addTarget(self, action: #selector(addressEdited), for: .editingChanged)
        field.addTarget(self, action: #selector(addressEdited), for: .editingDidEnd)

        let card = EmailLoginUI.fieldCard()
        let icon = EmailLoginUI.leadingGlyph("envelope")
        card.addSubview(icon)
        card.addSubview(field)
        card.addSubview(providerBadge)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            // Full-height and full-width (up to the badge) so tapping anywhere in
            // the card focuses the field, not just the sliver its text occupies.
            field.topAnchor.constraint(equalTo: card.topAnchor),
            field.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            // The badge stays installed and only fades (its width change on a
            // provider switch happens while it's invisible), so no layout jump.
            field.trailingAnchor.constraint(equalTo: providerBadge.leadingAnchor, constant: -8),
            providerBadge.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            providerBadge.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        let topStack = UIStackView(arrangedSubviews: [hero, titleLabel, bodyLabel, card])
        topStack.axis = .vertical
        topStack.alignment = .fill
        topStack.spacing = 16
        topStack.setCustomSpacing(24, after: bodyLabel)
        topStack.translatesAutoresizingMaskIntoConstraints = false

        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        continueButton.isEnabled = false
        view.addSubview(continueButton)

        // A scroll view (rather than plain centering) so a short device + a raised
        // keyboard never clips the card — matches OnboardingStepViewController's
        // "scroll when tall, center when it fits" layout.
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        content.addSubview(topStack)

        let contentFillsScroll = content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        contentFillsScroll.priority = .defaultLow

        // `keyboardLayoutGuide.topAnchor` already rests at the safe-area bottom
        // when no keyboard is shown, so this one required constraint alone gives a
        // sensible resting position AND rides above the keyboard while typing.
        let aboveKeyboard = continueButton.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        aboveKeyboard.priority = .required

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -16),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            contentFillsScroll,

            topStack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 16),
            topStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            topStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            topStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),

            continueButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            continueButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            aboveKeyboard,
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Establish the system input session only after the field is attached to
        // the presented window. Starting it from `viewDidLoad` can leave the
        // credential suggestion bar displaying a choice from a provisional session
        // that does not deliver its tap to this field.
        field.becomeFirstResponder()
    }

    /// Mirror of the field's text, kept current via `.editingChanged` so an
    /// AutoFilled value survives even if the field is cleared on return from a
    /// password-manager extension.
    private var enteredAddress = ""

    private func currentAddressCandidate() -> String {
        let typed = field.text ?? ""
        return typed.isEmpty ? enteredAddress : typed
    }

    /// The existing lightweight validation: no full RFC 5322 parse, just a shape
    /// check good enough to catch obvious typos before a network round trip.
    static func isValidAddress(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    @objc private func addressEdited() {
        if let text = field.text, !text.isEmpty { enteredAddress = text }
        let candidate = currentAddressCandidate().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        providerBadge.setProvider(ProviderBadgeText.text(for: ProviderInference.inferProviderID(for: candidate)))
        continueButton.isEnabled = Self.isValidAddress(candidate)
    }

    @objc private func cancel() { DotMatrixModal.dismiss(self) { self.completion?(false) } }

    /// Latched while autodiscovery runs: the return key and Continue button stay
    /// active during the (network) resolve, and repeated taps would push several
    /// credential screens onto the stack.
    private var isResolving = false

    @objc private func continueTapped() {
        guard !isResolving else { return }
        let address = currentAddressCandidate().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidAddress(address) else {
            field.shake()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let providerID = ProviderInference.inferProviderID(for: address)

        if providerID == .outlook {
            startOutlookOAuth(address: address)
            return
        }
        // App-password providers (and generic, resolved below). The only feedback
        // during this network wait used to be nothing at all — now the button
        // itself shows it's busy.
        isResolving = true
        continueButton.setLoading(true)
        field.isUserInteractionEnabled = false
        Task { @MainActor in
            defer {
                isResolving = false
                continueButton.setLoading(false)
                field.isUserInteractionEnabled = true
                addressEdited()   // re-derive Continue's enabled state
            }
            let server = await resolveServer(providerID: providerID, address: address)
            let account = EmailAccount(
                providerID: providerID, address: address, displayName: nil, server: server)
            let credential = CredentialViewController(
                account: account, accountStore: accountStore, completion: completion)
            navigationController?.pushViewController(credential, animated: true)
        }
    }

    /// Resolves IMAP/SMTP settings: the registry entry for known providers, or
    /// ISPDB autodiscovery (falling back to Gmail-like defaults) for custom domains.
    private func resolveServer(providerID: MailProvider.ID, address: String) async -> MailServerConfig {
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

    private var authSession: ASWebAuthenticationSession?
    private lazy var contextProvider = AuthPresentationContext(anchor: view.window)

    private func startOutlookOAuth(address: String) {
        let clientID = MicrosoftOAuth.clientID
        guard !clientID.isEmpty else {
            presentError("Outlook isn't configured in this build.")
            return
        }
        let pkce = MicrosoftOAuth.makePKCE()
        guard let url = MicrosoftOAuth.authorizationURL(
            clientID: clientID, challenge: pkce.challenge, loginHint: address)
        else { presentError("Couldn't start Outlook sign-in."); return }

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
                        return
                    }
                    self.presentError("Outlook sign-in failed. Please try again.")
                    return
                }
                guard let callback,
                      let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    // A callback without a `code` item is a real failure, not a
                    // cancellation — it must not fail silently.
                    self.presentError("Outlook sign-in failed. Please try again.")
                    return
                }
                // The webview is gone but the token exchange + inbox-filter setup
                // still run. Cover the (button-bearing) entry screen with a
                // full-screen dot-matrix spinner so nothing is tappable meanwhile.
                self.field.resignFirstResponder()
                let cover = EmailLoginLoadingCover(host: self.navigationController?.view ?? self.view)
                self.loadingCover = cover
                // The network round trip below is otherwise dead waiting time —
                // let the system permission dialog appear over the cover instead
                // of interrupting the user later at an arbitrary moment.
                NotificationManager.requestAuthorization()
                await self.exchangeOutlookCode(
                    code, verifier: pkce.verifier, clientID: clientID, address: address, cover: cover)
            }
        }
        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    @MainActor
    private func exchangeOutlookCode(
        _ code: String, verifier: String, clientID: String, address: String, cover: EmailLoginLoadingCover
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
            cover.resolveToCheckmark { self.finish() }
        } catch {
            cover.hide()
            loadingCover = nil
            presentError("Outlook sign-in failed. Please try again.")
        }
    }

    private func finish() {
        DotMatrixModal.dismiss(self) { self.completion?(true) }
    }

    // MARK: - Full-screen loading cover

    private var loadingCover: EmailLoginLoadingCover?

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Sign-in failed", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DotMatrixModal.present(alert, from: self)
    }
}
