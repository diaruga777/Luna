//
//  PluginCreateViewController.swift
//  LunaPluginUI
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import UIKit

/// Where a plugin is asked for: the user says what they want in their own
/// words, taps ChatGPT or Claude, and the reply comes back as a `.luna` file.
///
/// Luna writes no plugin itself and connects to no model. The screen's whole
/// job is to build one good prompt, remember the request, and say what to do
/// with the answer.
public final class PluginCreateViewController: UIViewController {

    private let handoffStore: LLMHandoffStore
    private let launcher: any LLMLaunching

    private let descriptionView = UITextView()
    private let placeholderLabel = UILabel()
    private let handoffRow = LLMHandoffRowView(
        caption: L10n.string("Plugins_create3RowCaption"))

    /// `prefill` is the failed card's or Safari's account of what went wrong.
    /// With none, a request already in flight fills the box instead.
    public init(
        prefill: String? = nil,
        handoffStore: LLMHandoffStore = .shared,
        launcher: any LLMLaunching
    ) {
        self.handoffStore = handoffStore
        self.launcher = launcher
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("Plugins_create1Title")
        descriptionView.text = prefill ?? ""
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.groupedBackground
        build()
        restoreRequestInFlight()
        updatePlaceholder()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if descriptionView.text.isEmpty { descriptionView.becomeFirstResponder() }
    }

    private func build() {
        descriptionView.font = .preferredFont(forTextStyle: .body)
        descriptionView.backgroundColor = LunaColors.secondaryBackground
        descriptionView.textColor = LunaColors.primaryText
        descriptionView.layer.cornerRadius = 12
        descriptionView.textContainerInset = UIEdgeInsets(
            top: 12, left: 12, bottom: 12, right: 12)
        descriptionView.delegate = self
        descriptionView.accessibilityLabel = L10n.string("Plugins_create2Placeholder")
        descriptionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(descriptionView)

        placeholderLabel.text = L10n.string("Plugins_create2Placeholder")
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = LunaColors.secondaryText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionView.addSubview(placeholderLabel)

        handoffRow.delegate = self
        handoffRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(handoffRow)

        let column = LunaLayout.readableWidth
        NSLayoutConstraint.activate([
            descriptionView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            descriptionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            descriptionView.widthAnchor.constraint(lessThanOrEqualToConstant: column),
            descriptionView.widthAnchor.constraint(
                lessThanOrEqualTo: view.widthAnchor, constant: -32),
            descriptionView.bottomAnchor.constraint(
                equalTo: handoffRow.topAnchor, constant: -20),

            placeholderLabel.topAnchor.constraint(
                equalTo: descriptionView.topAnchor, constant: 20),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: descriptionView.leadingAnchor, constant: 17),
            placeholderLabel.trailingAnchor.constraint(
                equalTo: descriptionView.trailingAnchor, constant: -17),

            handoffRow.centerXAnchor.constraint(equalTo: descriptionView.centerXAnchor),
            handoffRow.widthAnchor.constraint(equalTo: descriptionView.widthAnchor),
            handoffRow.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
    }

    /// A request already sent from any surface. The record holds the words the
    /// user typed, so coming back here — even from the share extension, which
    /// reads the same store — shows the request rather than an empty box.
    private func restoreRequestInFlight() {
        guard let record = handoffStore.pluginRecord(),
              case .plugin(let description, _) = record.kind else { return }
        if descriptionView.text.isEmpty { descriptionView.text = description }
        showWaiting(for: record.provider)
    }

    private func showWaiting(for provider: LLMProvider) {
        handoffRow.setHint(L10n.string("Plugins_create4Waiting", provider.displayName))
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !descriptionView.text.isEmpty
    }

    // MARK: - The prefill a failed page gives

    /// The description a failed save starts the request with: the URL, what
    /// went wrong, and the plugins that already claim the site. One builder, so
    /// the failed card and Safari's hand-off ask in the same words.
    public static func prefill(
        url: URL, failure: String?, matchedPluginIDs: [String] = []
    ) -> String {
        var lines = [url.absoluteString]
        if let failure, !failure.isEmpty {
            lines.append(L10n.string("Plugins_create5PrefillFailure", failure))
        }
        if !matchedPluginIDs.isEmpty {
            lines.append(L10n.string(
                "Plugins_create6PrefillPlugins", matchedPluginIDs.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    /// The site the request is about: the first http(s) URL the description
    /// holds. The prompt names it in the manifest skeleton, so a description
    /// with no link simply gets a generic one.
    public static func host(inDescription description: String) -> String? {
        firstLink(inDescription: description)?.host?.lowercased()
    }

    /// The page a draft answering this request is tested against.
    public static func firstLink(inDescription description: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(description.startIndex..<description.endIndex, in: description)
        let matches = detector?.matches(in: description, options: [], range: range) ?? []
        for match in matches {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host?.isEmpty == false
            else { continue }
            return url
        }
        return nil
    }
}

extension PluginCreateViewController: UITextViewDelegate {
    public func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
    }
}

extension PluginCreateViewController: LLMHandoffRowDelegate {
    public func row(_ row: LLMHandoffRowView, didChoose provider: LLMProvider) {
        let description = descriptionView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            descriptionView.becomeFirstResponder()
            return
        }
        let host = Self.host(inDescription: description)
        let prompt = LLMHandoffPrompts.pluginCreation(description: description, host: host)
        guard let link = LLMDeepLink.url(for: provider, prompt: prompt) else { return }
        handoffStore.begin(.plugin(description: description, host: host), provider: provider)
        showWaiting(for: provider)
        descriptionView.resignFirstResponder()
        launcher.openLLM(link, fallback: LLMDeepLink.fallbackURL(for: provider, prompt: prompt))
    }
}
