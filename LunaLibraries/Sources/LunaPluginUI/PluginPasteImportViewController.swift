//
//  PluginPasteImportViewController.swift
//  LunaPluginUI
//
//  The "Paste source" leg of Settings → Plugins' Add button (§11.2): a bare
//  text view and an Import button, for a plugin whose source the user has on
//  the pasteboard or is typing by hand rather than opening from Files.
//

import LunaDesignSystem
import LunaModels
import UIKit

public protocol PluginPasteImportDelegate: AnyObject {
    func pluginPasteImport(_ controller: PluginPasteImportViewController, didSubmit sourceText: String)
}

public final class PluginPasteImportViewController: UIViewController {

    public weak var delegate: PluginPasteImportDelegate?

    private let textView = UITextView()
    private let importButton = UIButton(configuration: .filled())

    public init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.groupedBackground
        title = L10n.string("Plugins_pasteTitle")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_cancel"), style: .plain, target: self,
            action: #selector(cancelTapped))

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.backgroundColor = LunaColors.secondaryBackground
        textView.textColor = LunaColors.primaryText
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        var config = UIButton.Configuration.filled()
        config.title = L10n.string("Plugins_pasteImportButton")
        importButton.configuration = config
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        view.addSubview(importButton)

        let column = LunaLayout.readableWidth
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: column),
            textView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            textView.bottomAnchor.constraint(equalTo: importButton.topAnchor, constant: -16),

            importButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            importButton.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func importTapped() {
        let text = textView.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        delegate?.pluginPasteImport(self, didSubmit: text)
    }
}
