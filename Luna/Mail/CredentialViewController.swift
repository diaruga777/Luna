//
//  CredentialViewController.swift
//  Luna
//
//  Step 2 of connecting an email account: an app-specific password for the
//  provider `EmailAccountSetup` inferred and resolved from the entered address.
//  Pushed onto whatever navigation stack collected that address, and left in place
//  on success — `completion` owns what happens next. See
//  `claudedocs/email-login.md`.
//

import LunaMailAccount
import LunaMailTransport
import LunaDesignSystem
import LunaSocial
import UIKit

final class CredentialViewController: UIViewController {

    private let account: EmailAccount
    private let accountStore: EmailAccountStore
    private let completion: ((Bool) -> Void)?
    private let passwordField = UITextField()
    private let revealButton = UIButton(type: .system)
    private let signInButton = EmailLoginActionButton(title: "Sign In")
    private var didFinish = false

    init(
        account: EmailAccount,
        accountStore: EmailAccountStore,
        completion: ((Bool) -> Void)?
    ) {
        self.account = account
        self.accountStore = accountStore
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        // The hero owns the title; the back button (pushed, not presented at this
        // step) is the only nav-bar chrome.

        let hero = EmailLoginUI.heroTile(symbol: "key.fill")
        let titleLabel = EmailLoginUI.titleLabel(account.provider.displayName)
        let bodyLabel = EmailLoginUI.bodyLabel(
            account.provider.setupInstructions ?? "Enter an app-specific password for this account.")

        passwordField.placeholder = "App password"
        passwordField.font = .preferredFont(forTextStyle: .body)
        passwordField.isSecureTextEntry = true
        passwordField.autocapitalizationType = .none
        passwordField.autocorrectionType = .no
        // Deliberately no `textContentType`: AutoFill would offer the account's
        // real sign-in password (from a saved credential for this domain), which
        // is the wrong secret here — this field wants a separate app password.
        passwordField.returnKeyType = .go
        passwordField.borderStyle = .none
        passwordField.backgroundColor = .clear
        passwordField.contentVerticalAlignment = .center
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        // No delegate, same as the email field — return key is a control action.
        passwordField.addTarget(self, action: #selector(signIn), for: .editingDidEndOnExit)
        passwordField.addTarget(self, action: #selector(passwordEdited), for: .editingChanged)

        revealButton.tintColor = LunaColors.tertiaryText
        revealButton.setImage(UIImage(systemName: "eye"), for: .normal)
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.addTarget(self, action: #selector(toggleReveal), for: .touchUpInside)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)

        let card = EmailLoginUI.fieldCard()
        let icon = EmailLoginUI.leadingGlyph("key")
        card.addSubview(icon)
        card.addSubview(passwordField)
        card.addSubview(revealButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            passwordField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            // Full-height so tapping anywhere in the card focuses the field.
            passwordField.topAnchor.constraint(equalTo: card.topAnchor),
            passwordField.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            passwordField.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -8),
            revealButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            revealButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        var stackViews: [UIView] = [hero, titleLabel, bodyLabel, card]
        var appPasswordLinkButton: UIButton?
        if let url = account.provider.appPasswordURL {
            let button = UIButton(type: .system)
            button.setTitle("Create an app password…", for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.tintColor = GlassStyle.lunaBrandAccent
            button.addAction(UIAction { _ in UIApplication.shared.open(url) }, for: .touchUpInside)
            stackViews.append(button)
            appPasswordLinkButton = button
        }

        let topStack = UIStackView(arrangedSubviews: stackViews)
        topStack.axis = .vertical
        topStack.alignment = .fill
        topStack.spacing = 16
        topStack.setCustomSpacing(24, after: bodyLabel)
        if let appPasswordLinkButton { topStack.setCustomSpacing(12, after: appPasswordLinkButton) }
        topStack.translatesAutoresizingMaskIntoConstraints = false

        signInButton.addTarget(self, action: #selector(signIn), for: .touchUpInside)
        signInButton.isEnabled = false
        view.addSubview(signInButton)

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

        let aboveKeyboard = signInButton.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        aboveKeyboard.priority = .required

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: signInButton.topAnchor, constant: -16),

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

            signInButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            signInButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            aboveKeyboard,
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Same windowing reason as the email field: only after the view is
        // attached to the presented (here: pushed) window.
        passwordField.becomeFirstResponder()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil, !didFinish {
            didFinish = true
            completion?(false)
        }
    }

    @objc private func passwordEdited() {
        signInButton.isEnabled = !(passwordField.text ?? "").isEmpty
    }

    @objc private func toggleReveal() {
        passwordField.isSecureTextEntry.toggle()
        // Re-set the text: toggling `isSecureTextEntry` on a live UITextField can
        // otherwise leave stale glyphs or jump the caret to the start.
        if let existing = passwordField.text {
            passwordField.text = nil
            passwordField.text = existing
        }
        revealButton.setImage(
            UIImage(systemName: passwordField.isSecureTextEntry ? "eye" : "eye.slash"), for: .normal)
    }

    /// App-password providers (Gmail/iCloud/Yahoo) display the generated code in
    /// spaced groups ("xxxx xxxx xxxx xxxx"), and copying it commonly carries those
    /// display spaces along — so strip ALL whitespace, not just the edges. Custom
    /// IMAP servers (`.generic`) take unconstrained free-form passwords that could
    /// legitimately contain an internal space, so only the edges are trimmed there.
    /// Pure + static so it's unit-testable without a live text field.
    static func normalizedPassword(_ raw: String, providerID: MailProvider.ID) -> String {
        guard providerID != .generic else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    @objc private func signIn() {
        let password = Self.normalizedPassword(passwordField.text ?? "", providerID: account.providerID)
        guard !password.isEmpty else { passwordField.shake(); return }
        signInButton.isEnabled = false
        passwordField.isUserInteractionEnabled = false
        passwordField.resignFirstResponder()
        let cover = EmailLoginLoadingCover(host: navigationController?.view ?? view)
        // Idempotent (authorization is requested at launch too) — but if that
        // prompt is somehow still unanswered, the network round trip below is
        // dead waiting time the system dialog can share.
        NotificationManager.requestAuthorization()

        Task { @MainActor in
            do {
                let transport = try IMAPSMTPTransport(account: account, password: password)
                try await transport.verifyCredentials()
                accountStore.save(account, credential: .appPassword(password))
                cover.resolveToCheckmark { [self] in
                    cover.hide()
                    didFinish = true
                    completion?(true)
                }
            } catch {
                cover.hide()
                signInButton.isEnabled = true
                passwordField.isUserInteractionEnabled = true
                let alert = UIAlertController(
                    title: "Couldn't sign in", message: Self.errorMessage(for: error), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    /// IMAP/SMTP transport failures split into two flavors worth telling apart:
    /// the transport (`StreamIMAPClient`/`StreamSMTPClient`, backed by
    /// `URLSessionStreamTask`) surfaces unreachable-host/timeout failures as
    /// `NSURLErrorDomain`/`NSPOSIXErrorDomain`/CFNetwork errors, while a wrong
    /// address or password comes back as a protocol-level `IMAPError`/`SMTPError`
    /// (a plain Swift error, in neither domain) after the server actually replied.
    /// This is a pragmatic domain check, not an exhaustive one — a
    /// `MailStream.StreamError` (e.g. connection dropped mid-exchange) isn't in
    /// these domains and reads as a credential failure, which is an acceptable
    /// simplification for now.
    private static let connectivityErrorDomains: Set<String> = [
        NSURLErrorDomain, NSPOSIXErrorDomain, "kCFErrorDomainCFNetwork",
    ]

    static func isConnectivityFailure(_ error: Error) -> Bool {
        connectivityErrorDomains.contains((error as NSError).domain)
    }

    private static func errorMessage(for error: Error) -> String {
        isConnectivityFailure(error)
            ? "Couldn't reach the mail servers. Check your connection and try again."
            : "Check the address and app password and try again."
    }
}
