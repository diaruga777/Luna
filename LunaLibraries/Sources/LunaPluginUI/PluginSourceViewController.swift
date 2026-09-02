//
//  PluginSourceViewController.swift
//  LunaPluginUI
//
//  "Show source" on the plugin detail screen: the installed file's text,
//  read-only, monospaced. Nothing here can edit or re-run the plugin.
//

import LunaDesignSystem
import LunaModels
import UIKit

public final class PluginSourceViewController: UIViewController {

    private let sourceText: String

    public init(pluginName: String, sourceText: String) {
        self.sourceText = sourceText
        super.init(nibName: nil, bundle: nil)
        title = pluginName
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.groupedBackground

        let textView = UITextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .clear
        textView.textColor = LunaColors.primaryText
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.text = sourceText
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
