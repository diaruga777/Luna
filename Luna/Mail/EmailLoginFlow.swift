//
//  EmailLoginFlow.swift
//  Luna
//

import LunaMailAccount
import LunaMailTransport
import LunaDesignSystem
import AuthenticationServices
import LunaTransitions
import UIKit

/// The email-account sign-in flow: enter an address → infer the provider →
/// either paste an app-specific password (Gmail/iCloud/Yahoo/custom) or run
/// OAuth (Outlook). Verifies before saving.
public enum EmailLoginFlow {

    /// Presents the flow modally. `completion(true)` when an account was connected.
    public static func present(from presenter: UIViewController, completion: ((Bool) -> Void)? = nil) {
        let entry = EmailEntryViewController(completion: completion)
        let nav = UINavigationController(rootViewController: entry)
        nav.modalPresentationStyle = .formSheet
        nav.installDotMatrixTransitions()
        DotMatrixModal.present(nav, from: presenter)
    }
}

// MARK: - Step 1: email address

final class EmailEntryViewController: UIViewController, UITextFieldDelegate {

    private let completion: ((Bool) -> Void)?
    private let field = UITextField()
    private let hint = UILabel()

    init(completion: ((Bool) -> Void)?) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Email Account"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Continue", style: .done, target: self, action: #selector(continueTapped))

        field.placeholder = "you@example.com"
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.textContentType = .emailAddress
        field.borderStyle = .roundedRect
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        hint.text = "Luna sends and reads shared articles through your own email account."
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(field)
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            field.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        field.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        continueTapped()
        return true
    }

    @objc private func cancel() { DotMatrixModal.dismiss(self) { self.completion?(false) } }

    /// Latched while autodiscovery runs: the return key and Continue button stay
    /// active during the (network) resolve, and repeated taps would push several
    /// credential screens onto the stack.
    private var isResolving = false

    @objc private func continueTapped() {
        guard !isResolving else { return }
        let address = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@"), address.contains(".") else {
            field.shake()
            return
        }
        let providerID = ProviderInference.inferProviderID(for: address)

        if providerID == .outlook {
            startOutlookOAuth(address: address)
            return
        }
        // App-password providers (and generic, resolved below).
        isResolving = true
        Task { @MainActor in
            defer { isResolving = false }
            let server = await resolveServer(providerID: providerID, address: address)
            let account = EmailAccount(
                providerID: providerID, address: address, displayName: nil, server: server)
            let credential = CredentialViewController(account: account, completion: completion)
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
        guard let url = MicrosoftOAuth.authorizationURL(clientID: clientID, challenge: pkce.challenge)
        else { presentError("Couldn't start Outlook sign-in."); return }

        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: MicrosoftOAuth.redirectScheme
        ) { [weak self] callback, _ in
            guard let self else { return }
            guard let callback,
                  let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
            else { return }
            Task { @MainActor in
                await self.exchangeOutlookCode(code, verifier: pkce.verifier,
                                               clientID: clientID, address: address)
            }
        }
        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    @MainActor
    private func exchangeOutlookCode(
        _ code: String, verifier: String, clientID: String, address: String
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
            EmailAccountStore.shared.save(account, credential: .oauth(tokens))
            // Best-effort: install the inbox filter.
            if let transport = MailTransportFactory.make() {
                _ = try? await transport.createLunaFilter()
            }
            finish()
        } catch {
            presentError("Outlook sign-in failed. Please try again.")
        }
    }

    private func finish() {
        DotMatrixModal.dismiss(self) { self.completion?(true) }
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Sign-in failed", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DotMatrixModal.present(alert, from: self)
    }
}

// MARK: - Step 2: app-specific password

final class CredentialViewController: UIViewController {

    private let account: EmailAccount
    private let completion: ((Bool) -> Void)?
    private let passwordField = UITextField()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(account: EmailAccount, completion: ((Bool) -> Void)?) {
        self.account = account
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = account.provider.displayName
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Sign In", style: .done, target: self, action: #selector(signIn))

        let instructions = UILabel()
        instructions.text = account.provider.setupInstructions
            ?? "Enter an app-specific password for this account."
        instructions.font = .preferredFont(forTextStyle: .callout)
        instructions.numberOfLines = 0
        instructions.translatesAutoresizingMaskIntoConstraints = false

        passwordField.placeholder = "App password"
        passwordField.isSecureTextEntry = true
        passwordField.autocapitalizationType = .none
        passwordField.autocorrectionType = .no
        passwordField.borderStyle = .roundedRect
        passwordField.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [instructions, passwordField])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        if let url = account.provider.appPasswordURL {
            let button = UIButton(type: .system)
            button.setTitle("Create an app password…", for: .normal)
            button.addAction(UIAction { _ in UIApplication.shared.open(url) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        passwordField.becomeFirstResponder()
    }

    @objc private func signIn() {
        let password = (passwordField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { passwordField.shake(); return }
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        spinner.startAnimating()

        Task { @MainActor in
            do {
                let transport = try IMAPSMTPTransport(account: account, password: password)
                try await transport.verifyCredentials()
                EmailAccountStore.shared.save(account, credential: .appPassword(password))
                DotMatrixModal.dismiss(self) { self.completion?(true) }
            } catch {
                spinner.stopAnimating()
                navigationItem.rightBarButtonItem = UIBarButtonItem(
                    title: "Sign In", style: .done, target: self, action: #selector(signIn))
                let alert = UIAlertController(
                    title: "Couldn't sign in",
                    message: "Check the address and app password and try again.",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                DotMatrixModal.present(alert, from: self)
            }
        }
    }
}

// MARK: - ASWebAuthenticationSession anchor

private final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var anchor: UIWindow?
    init(anchor: UIWindow?) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}

private extension UIView {
    /// A small horizontal shake to signal invalid input.
    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [-8, 8, -6, 6, -3, 3, 0]
        animation.duration = 0.4
        layer.add(animation, forKey: "shake")
    }
}
