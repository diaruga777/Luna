//
//  PluginRecoveryWorkshopViewController.swift
//  LunaPluginUI
//

import LunaDesignSystem
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import UIKit

/// The provider-neutral copy/paste loop for turning one failed or supplied URL
/// into a tested plugin. It deliberately has no LLM SDK or paid API dependency.
public final class PluginRecoveryWorkshopViewController: UIViewController {
    private let recoveryCase: PluginRecoveryCase
    private let importer: PluginImporting
    private lazy var importCoordinator: PluginImportCoordinator = {
        let value = PluginImportCoordinator(importer: importer)
        value.observer = self
        return value
    }()

    private let sourceView = UITextView()
    private let statusLabel = UILabel()
    private let validateButton = UIButton(type: .system)
    private let installButton = UIButton(type: .system)
    private let fixButton = UIButton(type: .system)
    private var report: PluginValidationReport?
    private var validatedSource: String?

    public init(recoveryCase: PluginRecoveryCase, importer: PluginImporting) {
        self.recoveryCase = recoveryCase
        self.importer = importer
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("Plugins_recoveryTitle")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.groupedBackground
        build()
    }

    private func build() {
        let scroll = UIScrollView()
        let stack = UIStackView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        stack.addArrangedSubview(label(
            L10n.string("Plugins_recoveryIntro", recoveryCase.host),
            font: .preferredFont(forTextStyle: .body)))
        let promptRow = UIStackView(arrangedSubviews: [
            button(L10n.string("Plugins_recoveryCopyPrompt"), symbol: "doc.on.doc", action: #selector(copyPrompt)),
            button(L10n.string("Plugins_recoverySharePrompt"), symbol: "square.and.arrow.up", action: #selector(sharePrompt)),
        ])
        promptRow.axis = .horizontal
        promptRow.distribution = .fillEqually
        promptRow.spacing = 10
        stack.addArrangedSubview(promptRow)
        stack.addArrangedSubview(label(
            L10n.string("Plugins_recoveryPasteLabel"),
            font: .preferredFont(forTextStyle: .headline)))

        sourceView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        sourceView.backgroundColor = LunaColors.secondaryBackground
        sourceView.layer.cornerRadius = 12
        sourceView.autocapitalizationType = .none
        sourceView.autocorrectionType = .no
        sourceView.smartQuotesType = .no
        sourceView.smartDashesType = .no
        sourceView.accessibilityLabel = L10n.string("Plugins_recoveryPasteLabel")
        sourceView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        stack.addArrangedSubview(sourceView)

        validateButton.configuration = actionConfiguration(
            L10n.string("Plugins_recoveryValidate"), symbol: "checkmark.shield", prominent: true)
        validateButton.addTarget(self, action: #selector(validateTapped), for: .touchUpInside)
        stack.addArrangedSubview(validateButton)

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = LunaColors.secondaryText
        statusLabel.isHidden = true
        stack.addArrangedSubview(statusLabel)

        fixButton.configuration = actionConfiguration(
            L10n.string("Plugins_recoveryCopyFix"), symbol: "arrow.triangle.2.circlepath", prominent: false)
        fixButton.addTarget(self, action: #selector(copyFix), for: .touchUpInside)
        fixButton.isHidden = true
        stack.addArrangedSubview(fixButton)

        installButton.configuration = actionConfiguration(
            L10n.string("Plugins_recoveryInstall"), symbol: "square.and.arrow.down", prominent: true)
        installButton.addTarget(self, action: #selector(install), for: .touchUpInside)
        installButton.isHidden = true
        stack.addArrangedSubview(installButton)
    }

    private func label(_ text: String, font: UIFont) -> UILabel {
        let value = UILabel()
        value.text = text
        value.font = font
        value.textColor = LunaColors.primaryText
        value.numberOfLines = 0
        return value
    }

    private func button(_ title: String, symbol: String, action: Selector) -> UIButton {
        let value = UIButton(type: .system)
        value.configuration = actionConfiguration(title, symbol: symbol, prominent: false)
        value.addTarget(self, action: action, for: .touchUpInside)
        return value
    }

    private func actionConfiguration(
        _ title: String, symbol: String, prominent: Bool
    ) -> UIButton.Configuration {
        var value = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        value.title = title
        value.image = UIImage(systemName: symbol)
        value.imagePadding = 7
        return value
    }

    @objc private func copyPrompt() {
        confirmSharing { UIPasteboard.general.string = PluginRecoveryPromptBuilder.initialPrompt(for: self.recoveryCase) }
    }

    @objc private func sharePrompt() {
        confirmSharing { [weak self] in
            guard let self else { return }
            do {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "luna-plugin-prompt-\(recoveryCase.caseID.uuidString.prefix(8)).txt")
                try PluginRecoveryPromptBuilder.initialPrompt(for: recoveryCase)
                    .write(to: file, atomically: true, encoding: .utf8)
                LunaShareSheet.present(items: [file], from: self, anchor: .view(self.view))
            } catch { self.show(error.localizedDescription) }
        }
    }

    private func confirmSharing(_ action: @escaping () -> Void) {
        let alert = UIAlertController(
            title: L10n.string("Plugins_recoveryPrivacyTitle"),
            message: L10n.string("Plugins_recoveryPrivacyMessage"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Common_continue"), style: .default) { _ in action() })
        present(alert, animated: true)
    }

    @objc private func validateTapped() {
        let normalized: String
        do {
            normalized = try PluginDraftSource.normalize(sourceView.text)
            sourceView.text = normalized
        } catch {
            show(error.localizedDescription)
            return
        }
        validatedSource = nil
        report = nil
        validateButton.isEnabled = false
        installButton.isHidden = true
        fixButton.isHidden = true
        show(L10n.string("Plugins_recoveryValidating"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await PluginDraftValidator.validate(
                sourceText: normalized, recoveryCase: recoveryCase)
            validateButton.isEnabled = true
            report = result
            if result.passed {
                validatedSource = normalized
                show(L10n.string("Plugins_recoveryPassed", result.modelKind ?? "Model"))
                installButton.isHidden = false
            } else {
                show(result.errors.joined(separator: "\n"))
                fixButton.isHidden = false
            }
        }
    }

    @objc private func copyFix() {
        guard let report else { return }
        let source = sourceView.text ?? ""
        confirmSharing {
            UIPasteboard.general.string = PluginRecoveryPromptBuilder.correctionPrompt(
                for: self.recoveryCase, draftSource: source, report: report)
        }
    }

    @objc private func install() {
        guard let validatedSource,
              (try? PluginDraftSource.normalize(sourceView.text)) == validatedSource else {
            show(L10n.string("Plugins_recoveryRevalidate"))
            installButton.isHidden = true
            return
        }
        importCoordinator.begin(sourceText: validatedSource, from: self)
    }

    private func show(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }
}

extension PluginRecoveryWorkshopViewController: PluginImportObserving {
    public func pluginImportDidFinish(_ coordinator: PluginImportCoordinator) {
        show(L10n.string("Plugins_recoveryInstalled"))
        installButton.isHidden = true
    }
}
