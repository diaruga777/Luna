//
//  PluginConsentViewController.swift
//  LunaPluginUI
//
//  The one screen a plugin is imported through (plugin-platform.md §15).
//  Declining is not a cancel: `PluginImportCoordinator` never calls install()
//  for a declined preview, so nothing is written.
//

import LunaDesignSystem
import LunaModels
import LunaPluginKit
import UIKit

/// The answer the consent screen took.
public protocol PluginConsentDelegate: AnyObject {
    func pluginConsent(
        _ controller: PluginConsentViewController, didDecide accepted: Bool,
        for preview: PluginImportPreview)
}

public final class PluginConsentViewController: UIViewController {

    private var preview: PluginImportPreview
    public weak var delegate: PluginConsentDelegate?

    private let stack = UIStackView()

    public init(preview: PluginImportPreview) {
        self.preview = preview
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.groupedBackground

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        // A consent screen is prose: it keeps a readable column rather than a
        // full-width band, on every width.
        let column = LunaLayout.readableWidth
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: column),
            stack.widthAnchor.constraint(
                lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])

        stack.addArrangedSubview(label(headline, font: .preferredFont(forTextStyle: .title1)))
        stack.addArrangedSubview(
            label(preview.summary.name, font: .preferredFont(forTextStyle: .headline)))
        stack.addArrangedSubview(
            label(
                L10n.string("Plugins_consentVersionLine", preview.summary.version),
                color: LunaColors.secondaryText))
        if let replaces = preview.replacesVersion {
            stack.addArrangedSubview(
                label(
                    L10n.string("Plugins_consentReplacesLine", replaces),
                    color: LunaColors.secondaryText))
        }

        if !preview.summary.produces.isEmpty {
            stack.addArrangedSubview(
                label(
                    L10n.string(
                        "Plugins_consentProducesLine",
                        preview.summary.produces.map(PluginCapabilityCopy.sentence(for:))
                            .joined(separator: ", ")),
                    color: LunaColors.secondaryText))
        }
        if let export = preview.summary.export {
            stack.addArrangedSubview(
                label(
                    L10n.string("Plugins_consentExportLine", export.title),
                    color: LunaColors.secondaryText))
        }
        if preview.runsInBackground {
            stack.addArrangedSubview(label(L10n.string("Plugins_consentBackgroundLine")))
        }

        stack.addArrangedSubview(
            label(
                L10n.string("Plugins_consentCapabilitiesHeader"),
                font: .preferredFont(forTextStyle: .headline)))
        if preview.capabilities.isEmpty {
            stack.addArrangedSubview(label(L10n.string("Plugins_consentNoCapabilities")))
        }
        let added = Set(preview.addedCapabilities)
        for capability in preview.capabilities {
            let sentence = "•  " + PluginCapabilityCopy.sentence(for: capability)
            stack.addArrangedSubview(
                label(
                    added.contains(capability) && preview.replacesVersion != nil
                        ? L10n.string("Plugins_consentAddedCapability", sentence)
                        : sentence))
        }

        if preview.summary.produces.contains(.media) {
            stack.addArrangedSubview(PluginSafariPlayerToggle(isOn: preview.autoShowSafariPlayer) { [weak self] enabled in
                self?.preview.autoShowSafariPlayer = enabled
            })
        }

        stack.addArrangedSubview(
            label(
                PluginCapabilityCopy.containmentDisclosure,
                font: .preferredFont(forTextStyle: .footnote),
                color: LunaColors.secondaryText))

        stack.addArrangedSubview(
            button(
                L10n.string(preview.requiresConsent ? "Plugins_consentAllowButton" : "Plugins_updateConfirmButton"),
                action: #selector(accept), prominent: true))
        stack.addArrangedSubview(
            button(L10n.string("Plugins_consentDontAllowButton"), action: #selector(decline), prominent: false))
    }

    private var headline: String {
        if preview.replacesVersion != nil {
            return preview.requiresConsent
                ? L10n.string("Plugins_consentUpdateHeadline")
                : L10n.string("Plugins_updateConfirmTitle", preview.summary.name)
        }
        return L10n.string("Plugins_consentHeadline")
    }

    private func label(
        _ text: String,
        font: UIFont = .preferredFont(forTextStyle: .body),
        color: UIColor = LunaColors.primaryText
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func button(_ title: String, action: Selector, prominent: Bool) -> UIButton {
        var configuration = prominent
            ? UIButton.Configuration.filled()
            : UIButton.Configuration.plain()
        configuration.title = title
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func accept() {
        delegate?.pluginConsent(self, didDecide: true, for: preview)
    }

    @objc private func decline() {
        delegate?.pluginConsent(self, didDecide: false, for: preview)
    }
}

/// Shared by file/paste consent and generated-draft review; changing a preview
/// never persists anything until the user installs it.
final class PluginSafariPlayerToggle: UIStackView {
    init(isOn: Bool, onChange: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 12
        let label = UILabel()
        label.text = L10n.string("Plugins_autoShowSafariPlayer")
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = LunaColors.primaryText
        label.numberOfLines = 0
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.accessibilityLabel = label.text
        toggle.addAction(UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        addArrangedSubview(label)
        addArrangedSubview(toggle)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
