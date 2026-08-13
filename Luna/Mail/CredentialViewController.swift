//
//  CredentialViewController.swift
//  Luna
//
//  Step 2 of connecting an email account. Asks for the app-specific password
//  for the provider that `EmailAccountSetup` resolved from the entered address.
//  This screen pushes onto the caller's navigation stack and stays on success;
//  `completion` decides what happens next. See `claudedocs/email-login.md`.
//

import LunaMailAccount
import LunaMailTransport
import LunaDesignSystem
import LunaSocial
import UIKit
import LunaModels

final class CredentialViewController: UIViewController {

    private let account: EmailAccount
    private let accountStore: EmailAccountStore
    private let completion: ((Bool) -> Void)?
    private let passwordField = UITextField()
    private let revealButton = UIButton(type: .system)
    private let signInButton = EmailLoginActionButton(title: L10n.string("Settings_email_credential_signInButton"))
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
        // The hero view owns the title. The pushed back button is the only
        // nav-bar chrome at this step.

        let hero = EmailLoginUI.heroTile(symbol: "key.fill")
        let titleLabel = EmailLoginUI.titleLabel(account.provider.displayName)
        let bodyLabel = EmailLoginUI.bodyLabel(
            account.provider.setupInstructions
                ?? L10n.string("Settings_email_credential_bodyFallback"))

        passwordField.placeholder = L10n.string("Settings_email_credential_passwordPlaceholder")
        passwordField.font = .preferredFont(forTextStyle: .body)
        passwordField.isSecureTextEntry = true
        passwordField.autocapitalizationType = .none
        passwordField.autocorrectionType = .no
        // No `textContentType`. AutoFill would offer the account's saved sign-in
        // password for this domain, but this field needs a separate app password.
        passwordField.returnKeyType = .go
        passwordField.borderStyle = .none
        passwordField.backgroundColor = .clear
        passwordField.contentVerticalAlignment = .center
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        // No delegate. Like the email field, the return key acts through a control action.
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
            button.setTitle(L10n.string("Settings_email_credential_createPasswordLink"), for: .normal)
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
        // Same reason as the email field: the window is ready only after the
        // view attaches — here, after the push completes.
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
        // Reset the text. Toggling `isSecureTextEntry` on a live field can leave
        // stale glyphs or move the caret to the start.
        if let existing = passwordField.text {
            passwordField.text = nil
            passwordField.text = existing
        }
        revealButton.setImage(
            UIImage(systemName: passwordField.isSecureTextEntry ? "eye" : "eye.slash"), for: .normal)
    }

    /// App-password providers (Gmail, iCloud, Yahoo) show the generated code in
    /// spaced groups, and copying it usually copies those spaces too. This strips
    /// all whitespace for those providers. A custom IMAP server (`.generic`) can
    /// take a free-form password with a real internal space, so it only trims the
    /// edges. Static and pure, so a test can call it without a live text field.
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
        // One of the three moments Luna asks for notification permission (never at
        // launch): connecting an account means an incoming share can be announced.
        // Asked before the network round trip so the system dialog overlaps the
        // wait. The call is idempotent, so re-signing in does not ask again.
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
                    title: L10n.string("Settings_email_credential_signInFailedTitle"), message: Self.errorMessage(for: error), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    /// Splits IMAP/SMTP failures into two kinds. The transport
    /// (`StreamIMAPClient`/`StreamSMTPClient`, over `URLSessionStreamTask`)
    /// reports unreachable-host or timeout failures in `NSURLErrorDomain`,
    /// `NSPOSIXErrorDomain`, or CFNetwork. A wrong address or password comes back
    /// as `IMAPError`/`SMTPError` once the server has replied. This check is not
    /// exhaustive: a `MailStream.StreamError` (for example, a dropped connection)
    /// falls outside these domains and reads as a credential failure. That gap is
    /// accepted for now.
    private static let connectivityErrorDomains: Set<String> = [
        NSURLErrorDomain, NSPOSIXErrorDomain, "kCFErrorDomainCFNetwork",
    ]

    static func isConnectivityFailure(_ error: Error) -> Bool {
        connectivityErrorDomains.contains((error as NSError).domain)
    }

    private static func errorMessage(for error: Error) -> String {
        isConnectivityFailure(error)
            ? L10n.string("Settings_email_credential_connectivityErrorMessage")
            : L10n.string("Settings_email_credential_credentialErrorMessage")
    }
}
