//
//  LinkImportSheetViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaReadingList
import LunaURLClassification
import UIKit

/// The import sheet: review what was found, watch it come in, read what landed.
///
/// One controller for all three because they are one continuous act — the table
/// stays put and its content is replaced, so the sheet never blinks out from
/// under the user mid-import (`claudedocs/import-export.md`).
final class LinkImportSheetViewController: UIViewController {

    // MARK: - Stage

    /// Internal, not private: the tests drive the sheet through its real stages.
    enum Stage {
        case review
        case importing
        case summary(LinkImportRunner.Summary)
    }

    /// One reviewable row.
    private struct Entry {
        let urlString: String
        /// The title the FILE carried, when it did — a Luna markdown export writes
        /// `[Title](url)`, so a re-import can read the headline straight off the
        /// page it came from and never has to fetch it.
        let fileTitle: String?
        var isSelected = true
    }

    /// The review stage's two lists and the summary's two, in one enum: the table
    /// is the same table throughout, and `visibleSections` picks per stage.
    private enum Section: CaseIterable {
        case links
        case archive
        case result
        case rejected
    }

    private(set) var stage: Stage = .review
    private var links: [Entry]
    private var archived: [Entry]
    private let isStructured: Bool

    private let runner: LinkImportRunner
    private var progressTimer: Timer?
    private var runTask: Task<Void, Never>?

    // MARK: - Views

    let table = UITableView(frame: .zero, style: .insetGrouped)
    let progressBar = MoonHorizonProgressBar()
    private let statusLabel = UILabel()
    private let countLabel = UILabel()
    private let progressStack = UIStackView()
    let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let buttonRow = UIStackView()
    /// Holds the progress block above the buttons. A stack, so hiding the block
    /// COLLAPSES it: `isHidden` on a plain subview leaves its frame (and the
    /// progress bar's 20pt intrinsic height) behind as a gap above the buttons.
    private let footerStack = UIStackView()
    private let titleLabel = UILabel()

    /// How often the pulled progress is read. 1/12 s is smooth for a bar whose
    /// head also animates its own travel, and cheap: reading it is a lock and a
    /// sum over the slice array.
    private static let progressTick: TimeInterval = 1.0 / 12.0

    // MARK: - Init

    init(document: LinkListDocument, runner: LinkImportRunner = LinkImportRunner()) {
        self.links = document.links.map {
            Entry(urlString: $0, fileTitle: document.titles[$0])
        }
        self.archived = document.archived.map {
            Entry(urlString: $0, fileTitle: document.titles[$0])
        }
        self.isStructured = document.isStructured
        self.runner = runner
        super.init(nibName: nil, bundle: nil)
        // Most of the screen, and not dismissable by a swipe once links are
        // being saved — see `presentationControllerShouldDismiss`.
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            // Set on the sheet controller, not `presentationController`: that one
            // is still nil before the sheet is presented, so a delegate assigned
            // in init would silently never be installed and the swipe-away guard
            // below would never run.
            sheet.delegate = self
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        progressTimer?.invalidate()
        runTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.groupedBackground
        AppearanceSettings.apply(to: self)
        buildLayout()
        applyStage()
    }

    private func buildLayout() {
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 0

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = LunaColors.secondaryText
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = LunaColors.tertiaryText
        countLabel.textAlignment = .center

        progressStack.axis = .vertical
        progressStack.spacing = 12
        progressStack.alignment = .fill
        progressStack.isLayoutMarginsRelativeArrangement = true
        progressStack.addArrangedSubview(statusLabel)
        progressStack.addArrangedSubview(progressBar)
        progressStack.addArrangedSubview(countLabel)

        primaryButton.addTarget(self, action: #selector(primaryPressed), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryPressed), for: .touchUpInside)
        for button in [primaryButton, secondaryButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
        }
        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 12
        buttonRow.addArrangedSubview(secondaryButton)
        buttonRow.addArrangedSubview(primaryButton)

        footerStack.axis = .vertical
        footerStack.spacing = 16
        footerStack.addArrangedSubview(progressStack)
        footerStack.addArrangedSubview(buttonRow)

        for subview in [titleLabel, table, footerStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        let guide = view.safeAreaLayoutGuide
        // The same readable column every settings screen keeps on a wide
        // container, so an iPad doesn't stretch a URL across 1300 points.
        let column = table.widthAnchor.constraint(equalTo: guide.widthAnchor)
        column.priority = .defaultHigh
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            table.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            table.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            table.widthAnchor.constraint(lessThanOrEqualToConstant: LunaLayout.readableWidth),
            column,
            table.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),

            footerStack.topAnchor.constraint(equalTo: table.bottomAnchor, constant: 8),
            footerStack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            footerStack.widthAnchor.constraint(equalTo: table.widthAnchor),
            footerStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Stage rendering

    var selectedCandidates: [LinkImportRunner.Candidate] {
        links.filter(\.isSelected).map {
            LinkImportRunner.Candidate(urlString: $0.urlString, isArchived: false)
        }
        + archived.filter(\.isSelected).map {
            LinkImportRunner.Candidate(urlString: $0.urlString, isArchived: true)
        }
    }

    private func applyStage() {
        switch stage {
        case .review:
            titleLabel.text = L10n.string("Import Links")
            table.isHidden = false
            table.allowsSelection = true
            progressStack.isHidden = true
            secondaryButton.isHidden = false
            secondaryButton.setTitle(L10n.string("Cancel"), for: .normal)
            primaryButton.setTitle(L10n.string("Import"), for: .normal)
            primaryButton.isEnabled = !selectedCandidates.isEmpty
            statusLabel.text = nil
            countLabel.text = nil
            table.reloadData()

        case .importing:
            titleLabel.text = L10n.string("Importing…")
            // The list stays up, frozen: its checkmarks are the record of what
            // the user chose, and hiding it would leave the sheet's middle blank
            // with the bar stranded at the bottom.
            table.isHidden = false
            table.allowsSelection = false
            progressStack.isHidden = false
            secondaryButton.isHidden = true
            primaryButton.setTitle(L10n.string("Stop"), for: .normal)
            primaryButton.isEnabled = true

        case let .summary(summary):
            titleLabel.text = summary.wasCancelled
                ? L10n.string("Import Stopped") : L10n.string("Import Finished")
            table.isHidden = false
            table.allowsSelection = false
            progressStack.isHidden = true
            secondaryButton.isHidden = true
            primaryButton.setTitle(L10n.string("Done"), for: .normal)
            primaryButton.isEnabled = true
            table.reloadData()
        }
        updateAccessibilityFocus()
    }

    private func updateAccessibilityFocus() {
        UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
    }

    // MARK: - Buttons

    @objc private func primaryPressed() {
        switch stage {
        case .review: startImport()
        case .importing: runner.cancel()
        case .summary: dismiss(animated: true)
        }
    }

    @objc private func secondaryPressed() {
        guard case .review = stage else { return }
        dismiss(animated: true)
    }

    private func startImport() {
        runTask = Task { [weak self] in await self?.performImport() }
    }

    /// The import, awaited. `startImport` is just this wrapped in a `Task`; the
    /// split exists so the sheet can be driven to its summary in a test without
    /// racing a detached task.
    func performImport() async {
        let candidates = selectedCandidates
        guard !candidates.isEmpty, case .review = stage else { return }
        stage = .importing
        applyStage()
        // The bar starts at nothing rather than jumping: the first slice's own
        // estimate takes over within a tick.
        progressBar.setProgress(0, animated: false)
        startProgressTimer()

        let summary = await runner.run(candidates)
        finish(with: summary)
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: Self.progressTick, repeats: true) { [weak self] _ in
            self?.refreshProgress()
        }
        // `.common` so a scroll or a presentation animation can't starve the bar.
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func refreshProgress() {
        let progress = runner.currentProgress()
        // `animated: false`: the 12 Hz pull IS the smoothness. Animating each tick
        // would stack a quarter-second implicit animation on top of the previous
        // one twelve times a second, which reads as lag rather than motion.
        progressBar.setProgress(Float(progress.fraction), animated: false)
        statusLabel.text = statusText(for: progress)
        guard progress.total > 0 else {
            countLabel.text = nil
            return
        }
        let done = progress.finished
        let total = progress.total
        countLabel.text = L10n.string("\(done) of \(total) finished")
    }

    private func statusText(for progress: LinkImportRunner.Progress) -> String {
        if runner.isCancelled { return L10n.string("Finishing the links already started…") }
        switch progress.phase {
        case .saving: return L10n.string("Saving links…")
        case .fetching: return L10n.string("Downloading content…")
        case .rescuing: return L10n.string("Retrying what failed with Apple Intelligence…")
        case .done: return L10n.string("Finishing up…")
        }
    }

    private func finish(with summary: LinkImportRunner.Summary) {
        progressTimer?.invalidate()
        progressTimer = nil
        progressBar.setProgress(1, animated: true)
        stage = .summary(summary)
        applyStage()
    }

    // MARK: - Summary rows

    /// The summary's lines, built once per render so the table and its
    /// accessibility text can't disagree.
    private func summaryLines(_ summary: LinkImportRunner.Summary) -> [(String, String?)] {
        let imported = summary.imported
        var lines: [(String, String?)] = [
            (
                L10n.string("\(imported) imported"),
                L10n.string("Saved, with their content ready.")
            ),
        ]
        if summary.recoverableFailures > 0 {
            let failures = summary.recoverableFailures
            lines.append((
                L10n.string("\(failures) couldn't be downloaded yet"),
                L10n.string("Saved anyway — Luna keeps retrying these on its own.")))
        }
        if summary.duplicates > 0 {
            let duplicates = summary.duplicates
            lines.append((
                L10n.string("\(duplicates) already saved"),
                L10n.string("Left exactly as they were.")))
        }
        return lines
    }
}

// MARK: - Table

extension LinkImportSheetViewController: UITableViewDataSource, UITableViewDelegate {

    /// The sections actually on screen for this stage, so an empty one is never
    /// rendered as a bare header — a file with only archived links should not
    /// show "Links (0)".
    private var visibleSections: [Section] {
        switch stage {
        case .review, .importing:
            return [.links, .archive].filter { !entries(for: $0).isEmpty }
        case let .summary(summary):
            return summary.rejected.isEmpty ? [.result] : [.result, .rejected]
        }
    }

    private func entries(for section: Section) -> [Entry] {
        switch section {
        case .links: return links
        case .archive: return archived
        case .result, .rejected: return []
        }
    }

    func numberOfSections(in _: UITableView) -> Int { visibleSections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .links: return links.count
        case .archive: return archived.count
        case .result:
            guard case let .summary(summary) = stage else { return 0 }
            return summaryLines(summary).count
        case .rejected:
            guard case let .summary(summary) = stage else { return 0 }
            return summary.rejected.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .links:
            let count = links.count
            return L10n.string("Links (\(count))")
        case .archive:
            let count = archived.count
            return L10n.string("Archive (\(count))")
        case .result:
            return L10n.string("Result")
        case .rejected:
            guard case let .summary(summary) = stage else { return nil }
            let count = summary.rejected.count
            return L10n.string("Not Saved (\(count))")
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .links, .archive:
            // Once, under the last section, and only when the file couldn't tell
            // us about an archive.
            guard section == visibleSections.count - 1, !isStructured else { return nil }
            return L10n.string(
                "This file didn't say which links were archived, so they'll all be saved as ordinary links.")
        case .result:
            guard case let .summary(summary) = stage, summary.wasCancelled else { return nil }
            return L10n.string(
                "The links you stopped before are saved too — Luna finishes them in the background.")
        case .rejected:
            return L10n.string("These aren't a kind this app handles, so nothing was saved for them.")
        }
    }

    func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let section = visibleSections[indexPath.section]
        if case let .summary(summary) = stage {
            return summaryCell(summary, section: section, row: indexPath.row)
        }
        let entry = entries(for: section)[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = entry.fileTitle ?? Self.displayTitle(for: entry.urlString)
        content.textProperties.numberOfLines = 1
        content.secondaryText = Self.displaySubtitle(for: entry.urlString)
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.color = LunaColors.tertiaryText
        // A leading circle that fills when chosen — the selection control sits
        // where the user's eye and thumb already are, and a FILLED circle reads as
        // "this one is included" without the trailing checkmark's suggestion that
        // the row was just tapped.
        content.image = UIImage(
            systemName: entry.isSelected ? "checkmark.circle.fill" : "circle")
        content.imageProperties.tintColor = entry.isSelected
            ? (view.tintColor ?? .systemBlue) : LunaColors.tertiaryText
        cell.contentConfiguration = content
        cell.accessibilityTraits = entry.isSelected ? [.button, .selected] : [.button]
        return cell
    }

    private func summaryCell(
        _ summary: LinkImportRunner.Summary, section: Section, row: Int
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if section == .result {
            let line = summaryLines(summary)[row]
            content.text = line.0
            content.secondaryText = line.1
        } else {
            let rejected = summary.rejected[row]
            content.text = Self.displayTitle(for: rejected.urlString)
            content.textProperties.numberOfLines = 1
            content.secondaryText = Self.rejectionText(rejected.reason)
            content.secondaryTextProperties.numberOfLines = 2
        }
        content.secondaryTextProperties.color = LunaColors.tertiaryText
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard case .review = stage else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        switch visibleSections[indexPath.section] {
        case .links: links[indexPath.row].isSelected.toggle()
        case .archive: archived[indexPath.row].isSelected.toggle()
        default: return
        }
        tableView.reloadRows(at: [indexPath], with: .none)
        primaryButton.isEnabled = !selectedCandidates.isEmpty
    }

    // MARK: - Row copy

    /// The row's first line: the path, which is the part that differs between two
    /// links from the same site and so the part worth reading. Falls back to the
    /// host for a bare domain.
    static func displayTitle(for urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let path = url.path
        if path.isEmpty || path == "/" {
            return url.host ?? urlString
        }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// The row's second line: the host, so the site is always visible even when
    /// the path is long enough to be truncated.
    static func displaySubtitle(for urlString: String) -> String? {
        URL(string: urlString)?.host
    }

    static func rejectionText(_ reason: LinkImportRunner.Rejection) -> String {
        switch reason {
        case let .foreignKind(owner):
            guard let owner else {
                return L10n.string("Another Luna app handles this kind of link.")
            }
            return String(
                format: L10n.string("%@ handles this kind of link."), owner.displayName)
        case .unusableURL:
            return L10n.string("Not a link Luna can open.")
        }
    }
}

// MARK: - Dismissal

extension LinkImportSheetViewController: UISheetPresentationControllerDelegate {
    /// A swipe-away mid-import would leave the run going with nothing showing it,
    /// so the sheet holds until the user stops it or it finishes. Review and
    /// summary dismiss freely.
    var allowsInteractiveDismissal: Bool {
        if case .importing = stage { return false }
        return true
    }

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool {
        allowsInteractiveDismissal
    }
}
