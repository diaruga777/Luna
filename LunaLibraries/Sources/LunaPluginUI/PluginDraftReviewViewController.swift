//
//  PluginDraftReviewViewController.swift
//  LunaPluginUI
//

import LunaDesignSystem
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaStorage
import UIKit

/// What the review screen finished with. The presenter owns the dismissal,
/// because the app pushes this screen and an extension hosts it.
@MainActor
public protocol PluginDraftReviewDelegate: AnyObject {
    /// The plugin is installed and the runtime is holding it.
    func pluginDraftReviewDidInstall(_ controller: PluginDraftReviewViewController)
    /// The user discarded the draft. Nothing was written.
    func pluginDraftReviewDidDiscard(_ controller: PluginDraftReviewViewController)
}

/// The one screen an arriving plugin draft is read on: what the file says it
/// is, what it may do, and what Luna's own test made of it.
///
/// It replaces the consent screen for this route. A file the user did not write
/// deserves MORE than the consent screen shows, not a second sheet after it, so
/// Save here is the consent: it records the draft's capabilities and installs
/// transactionally. `PluginConsentViewController` still serves the manual `+`
/// import, where the user already chose the file.
public final class PluginDraftReviewViewController: UIViewController {

    /// What the hand-off remembered about the request this draft answers.
    public struct Origin: Equatable, Sendable {
        /// The user's own words, carried into a correction prompt.
        public let description: String
        /// The site the request named, if any.
        public let host: String?
        /// A page to run the draft against. Absent means a load-only test.
        public let targetURL: URL?
        /// The hand-off record to clear once the draft is installed.
        public let recordID: UUID?

        public init(description: String, host: String?, targetURL: URL?, recordID: UUID?) {
            self.description = description
            self.host = host
            self.targetURL = targetURL
            self.recordID = recordID
        }
    }

    public weak var delegate: PluginDraftReviewDelegate?

    private let sourceText: String
    private let origin: Origin?
    private let importer: PluginImporting
    private let handoffStore: LLMHandoffStore
    private let launcher: any LLMLaunching

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let hooksLabel = UILabel()
    private let resultLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let discardButton = UIButton(type: .system)
    private let correctionRow = LLMHandoffRowView()

    private var preview: PluginImportPreview?
    private var manifest: PluginManifest?
    private var report: PluginValidationReport?

    public init(
        sourceText: String,
        origin: Origin? = nil,
        importer: PluginImporting,
        handoffStore: LLMHandoffStore = .shared,
        launcher: any LLMLaunching
    ) {
        self.sourceText = sourceText
        self.origin = origin
        self.importer = importer
        self.handoffStore = handoffStore
        self.launcher = launcher
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("Plugins_review01Title")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.groupedBackground
        buildLayout()
        readHeader()
        startValidation()
    }

    // MARK: - Layout

    private func buildLayout() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        view.addSubview(scroll)
        scroll.addSubview(stack)

        // A nutrition label is prose: it keeps a readable column on every width.
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
    }

    /// Everything the header alone can say, before the runtime has an opinion.
    private func readHeader() {
        let parsed: PluginImportPreview
        do {
            parsed = try importer.preview(sourceText: sourceText)
        } catch {
            showUnreadable(error.localizedDescription)
            return
        }
        preview = parsed
        manifest = try? PluginManifestParser.parse(source: sourceText).get()

        stack.addArrangedSubview(
            label(parsed.summary.name, font: .preferredFont(forTextStyle: .title2)))
        if let description = parsed.description, !description.isEmpty {
            stack.addArrangedSubview(label(description))
        }
        stack.addArrangedSubview(
            label(
                L10n.string("Plugins_consentVersionLine", parsed.summary.version),
                color: LunaColors.secondaryText))
        if let replaces = parsed.replacesVersion {
            stack.addArrangedSubview(
                label(
                    L10n.string("Plugins_consentReplacesLine", replaces),
                    color: LunaColors.secondaryText))
        }

        addProducesAndMatches(parsed.summary)
        addHooks()
        addCapabilities(parsed)
        addDeclarations(parsed)
        addResultSection()
        stack.addArrangedSubview(
            label(
                PluginCapabilityCopy.containmentDisclosure,
                font: .preferredFont(forTextStyle: .footnote), color: LunaColors.secondaryText))
        addButtons()
    }

    private func addProducesAndMatches(_ summary: PluginSummary) {
        if !summary.produces.isEmpty {
            stack.addArrangedSubview(
                label(L10n.string(
                    "Plugins_consentProducesLine",
                    summary.produces.map(PluginCapabilityCopy.sentence(for:))
                        .joined(separator: ", "))))
        }
        let where_ = summary.matchesAnyHost || summary.hostPatterns.isEmpty
            ? L10n.string("Plugins_review03AnyWebsite")
            : summary.hostPatterns.joined(separator: ", ")
        stack.addArrangedSubview(label(L10n.string("Plugins_review02Matches", where_)))
        stack.addArrangedSubview(
            label(
                L10n.string("Plugins_review04Priority", summary.priority),
                color: LunaColors.secondaryText))
    }

    /// The manifest's required hooks, joined with the ones the load step saw. A
    /// required hook the draft never registered is named as missing, which is
    /// the one difference a reader cannot get from the header. The line is
    /// rewritten once validation has run, because only then is the registered
    /// set known.
    private func addHooks() {
        hooksLabel.font = .preferredFont(forTextStyle: .body)
        hooksLabel.textColor = LunaColors.primaryText
        hooksLabel.numberOfLines = 0
        stack.addArrangedSubview(hooksLabel)
        refreshHooks()
    }

    private func refreshHooks() {
        guard let manifest else { return }
        let registered = Set(report?.registeredHooks ?? [])
        let hooks = manifest.requiredHooks.union(registered).sorted { $0.rawValue < $1.rawValue }
        let names = hooks.map { hook -> String in
            registered.isEmpty || registered.contains(hook)
                ? hook.rawValue
                : L10n.string("Plugins_review06HookMissing", hook.rawValue)
        }
        hooksLabel.isHidden = names.isEmpty
        hooksLabel.text = L10n.string("Plugins_review05Hooks", names.joined(separator: ", "))
    }

    private func addCapabilities(_ parsed: PluginImportPreview) {
        stack.addArrangedSubview(
            label(
                L10n.string("Plugins_consentCapabilitiesHeader"),
                font: .preferredFont(forTextStyle: .headline)))
        guard !parsed.capabilities.isEmpty else {
            stack.addArrangedSubview(label(L10n.string("Plugins_consentNoCapabilities")))
            return
        }
        let added = Set(parsed.addedCapabilities)
        for capability in parsed.capabilities {
            var line = "•  " + PluginCapabilityCopy.sentence(for: capability)
            if added.contains(capability), parsed.replacesVersion != nil {
                line = L10n.string("Plugins_consentAddedCapability", line)
            }
            if !PluginDraftValidator.servedCapabilities.contains(capability) {
                line = L10n.string("Plugins_review07CapabilityNotTested", line)
            }
            stack.addArrangedSubview(label(line))
        }
    }

    /// Settings fields, the background flag and the export declaration: the
    /// three things a manifest can promise that no capability line covers.
    private func addDeclarations(_ parsed: PluginImportPreview) {
        if let fields = manifest?.settings, !fields.isEmpty {
            stack.addArrangedSubview(
                label(L10n.string(
                    "Plugins_review08Settings",
                    fields.map(\.label).joined(separator: ", "))))
        }
        if parsed.runsInBackground {
            stack.addArrangedSubview(label(L10n.string("Plugins_consentBackgroundLine")))
        }
        if let export = parsed.summary.export {
            stack.addArrangedSubview(
                label(L10n.string("Plugins_consentExportLine", export.title)))
        }
    }

    private func addResultSection() {
        stack.addArrangedSubview(
            label(
                L10n.string("Plugins_review09ResultHeader"),
                font: .preferredFont(forTextStyle: .headline)))
        resultLabel.text = L10n.string("Plugins_review10Testing")
        resultLabel.font = .preferredFont(forTextStyle: .body)
        resultLabel.textColor = LunaColors.secondaryText
        resultLabel.numberOfLines = 0
        stack.addArrangedSubview(resultLabel)
    }

    private func addButtons() {
        saveButton.configuration = configuration(
            L10n.string("Plugins_review13Save"), prominent: true)
        saveButton.isEnabled = false
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        stack.addArrangedSubview(saveButton)

        discardButton.configuration = configuration(
            L10n.string("Plugins_review15Discard"), prominent: false)
        discardButton.addTarget(self, action: #selector(discardTapped), for: .touchUpInside)
        stack.addArrangedSubview(discardButton)

        correctionRow.caption = L10n.string("Plugins_review16GenerateAgain")
        correctionRow.delegate = self
        correctionRow.isHidden = true
        stack.addArrangedSubview(correctionRow)
    }

    /// A file whose header will not parse has nothing to review. The reader
    /// gets the parser's own sentence, Discard, and the way to ask again.
    private func showUnreadable(_ message: String) {
        stack.addArrangedSubview(
            label(
                L10n.string("Plugins_review18Unreadable", message),
                font: .preferredFont(forTextStyle: .body)))
        addButtons()
        correctionRow.isHidden = origin == nil
        report = PluginValidationReport(passed: false, errors: [message])
    }

    // MARK: - Validation

    private func startValidation() {
        guard preview != nil, manifest != nil else { return }
        let recoveryCase = origin.flatMap { origin -> PluginRecoveryCase? in
            guard let url = origin.targetURL ?? origin.host.flatMap({ URL(string: "https://\($0)") })
            else { return nil }
            return PluginRecoveryCase(originalURL: url.absoluteString, outcome: "failed")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await PluginDraftValidator.validate(
                sourceText: sourceText, recoveryCase: recoveryCase,
                targetURL: origin?.targetURL)
            report = result
            refreshHooks()
            showResult(result)
        }
    }

    private func showResult(_ result: PluginValidationReport) {
        var lines: [String] = []
        if result.passed {
            lines.append(
                result.modelKind.map { L10n.string("Plugins_review11Passed", $0) }
                    ?? L10n.string("Plugins_review12Loaded"))
        } else {
            lines.append(contentsOf: result.errors)
        }
        lines.append(contentsOf: result.warnings)
        resultLabel.text = lines.joined(separator: "\n")
        resultLabel.textColor = result.passed ? LunaColors.secondaryText : LunaColors.primaryText
        saveButton.isEnabled = true
        saveButton.configuration = configuration(
            result.passed
                ? L10n.string("Plugins_review13Save")
                : L10n.string("Plugins_review14SaveAnyway"),
            prominent: true)
        correctionRow.isHidden = result.passed || origin == nil
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        guard let preview else { return }
        saveButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await importer.installAsync(preview, origin: .files)
                if let recordID = origin?.recordID { handoffStore.clear(id: recordID) }
                resultLabel.text = L10n.string("Plugins_review17Installed")
                correctionRow.isHidden = true
                delegate?.pluginDraftReviewDidInstall(self)
            } catch {
                saveButton.isEnabled = true
                report(error)
            }
        }
    }

    @objc private func discardTapped() {
        delegate?.pluginDraftReviewDidDiscard(self)
    }

    private func report(_ error: Error) {
        let alert = UIAlertController(
            title: L10n.string("Plugins_importFailedTitle"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        present(alert, animated: true)
    }

    /// The findings the correction prompt carries: errors first, then warnings,
    /// bounded so the prompt keeps room for the request itself.
    var correctionErrors: [String] {
        guard let report else { return [] }
        return Array((report.errors + report.warnings).prefix(8))
    }

    // MARK: - Views

    private func label(
        _ text: String,
        font: UIFont = .preferredFont(forTextStyle: .body),
        color: UIColor = LunaColors.primaryText
    ) -> UILabel {
        let value = UILabel()
        value.text = text
        value.font = font
        value.textColor = color
        value.numberOfLines = 0
        return value
    }

    private func configuration(_ title: String, prominent: Bool) -> UIButton.Configuration {
        var value = prominent
            ? UIButton.Configuration.filled()
            : UIButton.Configuration.plain()
        value.title = title
        return value
    }
}

extension PluginDraftReviewViewController: LLMHandoffRowDelegate {
    public func row(_ row: LLMHandoffRowView, didChoose provider: LLMProvider) {
        guard let origin else { return }
        let prompt = LLMHandoffPrompts.pluginCorrection(
            description: origin.description, host: origin.host, errors: correctionErrors)
        let record = handoffStore.begin(
            kind: .plugin(description: origin.description, host: origin.host), provider: provider)
        row.hint = L10n.string("Plugins_create4Waiting", provider.displayName)
        _ = record
        launcher.launch(provider, prompt: prompt)
    }
}
