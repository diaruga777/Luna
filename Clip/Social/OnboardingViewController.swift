//
//  OnboardingViewController.swift
//  Clip
//

import UIKit

/// First-launch identity setup: pick a username (cosmetic, ≤20 chars) and
/// optionally an email/phone to share with friends. Creates the durable
/// UUID + key pairs in the synchronized Keychain on Continue.
///
/// Layout: a scroll view holds the title/fields so 100% of the content is
/// reachable on small (iPhone-mini) screens. The Continue button is pinned to
/// the keyboard layout guide so it rises just above the keyboard while editing
/// and returns to the bottom safe area when the keyboard hides. The focused
/// field is scrolled into the visible region above the keyboard.
final class OnboardingViewController: UIViewController, UITextFieldDelegate {

    private let identityStore: IdentityStoring
    private let onComplete: () -> Void

    private let usernameField = UITextField()
    private let emailField = UITextField()
    private let phoneField = UITextField()
    private let usernameCountLabel = UILabel()
    private let continueButton = UIButton(type: .system)
    private let scrollView = UIScrollView()

    /// Padding kept below the focused field when scrolling it into view.
    private static let focusedFieldPadding: CGFloat = 16

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
        titleLabel.text = "Welcome to Queue Reader"
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        // Wrap rather than truncate: the 32pt title overflows one line on narrow
        // devices (iPhone mini / regular iPhone), where it showed "Welcome to Queue R…".
        titleLabel.numberOfLines = 0

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
            emailField, phoneField, icloudNote,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(8, after: titleLabel)
        stack.setCustomSpacing(28, after: subtitleLabel)
        stack.setCustomSpacing(4, after: usernameField)
        stack.setCustomSpacing(24, after: icloudNote)

        // The scroll view holds the title + fields so everything is reachable on a
        // small screen; the Continue button is pinned outside it to the keyboard
        // layout guide so it always sits just above the keyboard (or the bottom
        // safe area when dismissed).
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        continueButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(continueButton)

        // Rise above the keyboard when it's up (the guide tracks the real keyboard
        // frame and animates with it); cap at the bottom safe area when it's down.
        let buttonAboveKeyboard = continueButton.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        buttonAboveKeyboard.priority = .defaultHigh
        let buttonAboveSafeArea = continueButton.bottomAnchor.constraint(
            lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -16),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            // Width matches the visible scroll frame (minus the leading/trailing
            // margins) so the content never scrolls horizontally.
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),

            continueButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            continueButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            continueButton.heightAnchor.constraint(equalToConstant: 52),
            buttonAboveKeyboard,
            buttonAboveSafeArea,

            usernameField.heightAnchor.constraint(equalToConstant: 44),
            emailField.heightAnchor.constraint(equalToConstant: 44),
            phoneField.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Tap on the blank background ends editing. cancelsTouchesInView = false so
        // taps still reach the text fields and the Continue button.
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dismissTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(dismissTap)

        observeKeyboard()
    }

    private func configureField(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.delegate = self
    }

    // MARK: - Keyboard avoidance

    private func observeKeyboard() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let endFrameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        let keyboardFrameInView = view.convert(endFrameValue.cgRectValue, from: view.window)
        let keyboardFrameInScroll = scrollView.convert(keyboardFrameInView, from: view)
        let inset = KeyboardAvoidance.bottomInset(
            keyboardFrameInView: keyboardFrameInScroll,
            scrollViewBounds: scrollView.bounds)
        scrollView.contentInset.bottom = inset
        scrollView.verticalScrollIndicatorInsets.bottom = inset
        scrollFocusedFieldIntoView(keyboardOverlap: inset)
    }

    @objc private func keyboardWillHide() {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    private func scrollFocusedFieldIntoView(keyboardOverlap: CGFloat) {
        let fields: [UITextField] = [usernameField, emailField, phoneField]
        guard let focused = fields.first(where: { $0.isFirstResponder }) else { return }
        let targetFrame = focused.convert(focused.bounds, to: scrollView)
        let visibleHeight = scrollView.bounds.height - keyboardOverlap
        let maxOffsetY = max(0, scrollView.contentSize.height - visibleHeight)
        guard let newOffsetY = KeyboardAvoidance.contentOffsetToReveal(
            targetFrame: targetFrame,
            currentOffsetY: scrollView.contentOffset.y,
            visibleHeight: visibleHeight,
            maxContentOffsetY: maxOffsetY,
            padding: Self.focusedFieldPadding)
        else { return }
        scrollView.setContentOffset(CGPoint(x: 0, y: newOffsetY), animated: true)
    }

    @objc private func backgroundTapped() {
        view.endEditing(true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === usernameField {
            emailField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return false
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
