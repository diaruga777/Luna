//
//  OnboardingViewController.swift
//  Clip
//

import UIKit

/// First-launch identity setup: pick a username (cosmetic, ≤20 chars) and
/// optionally an email/phone to share with friends. Creates the durable
/// UUID + key pairs in the synchronized Keychain on Continue.
final class OnboardingViewController: UIViewController, UITextFieldDelegate {

    private let identityStore: IdentityStoring
    private let onComplete: () -> Void

    private let usernameField = UITextField()
    private let emailField = UITextField()
    private let phoneField = UITextField()
    private let usernameCountLabel = UILabel()
    private let continueButton = UIButton(type: .system)

    init(identityStore: IdentityStoring = KeychainIdentityStore.shared,
         onComplete: @escaping () -> Void) {
        self.identityStore = identityStore
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "Welcome to Click Reader"
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Pick a username so friends can recognize you. You can share articles with friends over iCloud."
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        configureField(usernameField, placeholder: "Username (required)")
        usernameField.returnKeyType = .next
        usernameField.addTarget(self, action: #selector(usernameChanged), for: .editingChanged)

        usernameCountLabel.font = .preferredFont(forTextStyle: .caption1)
        usernameCountLabel.textColor = .tertiaryLabel
        usernameCountLabel.textAlignment = .right
        usernameCountLabel.text = "0/\(ProfileValidation.usernameMaxLength)"

        configureField(emailField, placeholder: "Email (optional, shared with friends)")
        emailField.keyboardType = .emailAddress
        configureField(phoneField, placeholder: "Phone (optional, shared with friends)")
        phoneField.keyboardType = .phonePad

        let icloudNote = UILabel()
        icloudNote.text = "Sharing with friends requires being signed into iCloud."
        icloudNote.font = .preferredFont(forTextStyle: .footnote)
        icloudNote.textColor = .secondaryLabel
        icloudNote.numberOfLines = 0

        continueButton.setTitle("Continue", for: .normal)
        continueButton.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
        continueButton.backgroundColor = .systemBlue
        continueButton.setTitleColor(.white, for: .normal)
        continueButton.layer.cornerRadius = 14
        continueButton.isEnabled = false
        continueButton.alpha = 0.4
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, subtitleLabel, usernameField, usernameCountLabel,
            emailField, phoneField, icloudNote, continueButton,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(8, after: titleLabel)
        stack.setCustomSpacing(28, after: subtitleLabel)
        stack.setCustomSpacing(4, after: usernameField)
        stack.setCustomSpacing(24, after: icloudNote)

        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
            continueButton.heightAnchor.constraint(equalToConstant: 52),
            usernameField.heightAnchor.constraint(equalToConstant: 44),
            emailField.heightAnchor.constraint(equalToConstant: 44),
            phoneField.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureField(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.delegate = self
    }

    @objc private func usernameChanged() {
        let count = usernameField.text?.count ?? 0
        usernameCountLabel.text = "\(count)/\(ProfileValidation.usernameMaxLength)"
        let isValid = ProfileValidation.normalizedUsername(usernameField.text ?? "") != nil
        continueButton.isEnabled = isValid
        continueButton.alpha = isValid ? 1 : 0.4
    }

    /// Hard-caps the username field at the limit while typing.
    func textField(
        _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        guard textField === usernameField else { return true }
        let current = (textField.text ?? "") as NSString
        let proposed = current.replacingCharacters(in: range, with: string)
        return proposed.count <= ProfileValidation.usernameMaxLength
    }

    @objc private func continueTapped() {
        guard identityStore.createIdentity(
            username: usernameField.text ?? "",
            email: emailField.text,
            phone: phoneField.text) != nil
        else { return }
        Task {
            await SocialMessageCenter.shared.ensureSubscription()
        }
        onComplete()
    }
}
