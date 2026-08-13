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

    /// One reviewable row. Internal, not private: the row-copy helpers below are
    /// pure functions of it, and the tests exercise them directly.
    struct Entry {
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
    /// Titles and thumbnails for the rows the user can see, fetched in a rolling
    /// window (`LinkImportPreviewLoader`).
    private let previews: LinkImportPreviewLoader
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

    /// A review row's height before anything is measured: the thumbnail box plus
    /// the usual cell padding, so the first layout doesn't have to guess low and
    /// then grow every row when the pictures arrive.
    private static let previewRowHeight: CGFloat =
        LinkImportPreviewLoader.thumbnailSize.height + 22

    // MARK: - Init

    /// `previews` defaults to `nil` rather than to a fresh loader, and is
    /// resolved in the body: a default argument is evaluated in the CALLER's
    /// context, which is not the main actor even though this initializer is,
    /// and the loader owns main-actor UIKit state. The body is the first place
    /// that isolation is guaranteed.
    @MainActor
    init(
        document: LinkListDocument,
        runner: LinkImportRunner = LinkImportRunner(),
        previews: LinkImportPreviewLoader? = nil
    ) {
        self.links = document.links.map {
            Entry(urlString: $0, fileTitle: document.titles[$0])
        }
        self.archived = document.archived.map {
            Entry(urlString: $0, fileTitle: document.titles[$0])
        }
        self.isStructured = document.isStructured
        self.runner = runner
        self.previews = previews ?? LinkImportPreviewLoader()
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
        table.prefetchDataSource = self
        table.backgroundColor = .clear
        // A row's picture arrives after the row does, so the table has to be able
        // to grow for it; a fixed estimate keeps the first layout cheap.
        table.estimatedRowHeight = Self.previewRowHeight
        previews.delegate = self

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
            titleLabel.text = L10n.string("Settings_linkImport_reviewTitle")
            table.isHidden = false
            table.allowsSelection = true
            progressStack.isHidden = true
            secondaryButton.isHidden = false
            secondaryButton.setTitle(L10n.string("Common_cancel"), for: .normal)
            primaryButton.setTitle(L10n.string("Settings_linkImport_importButton"), for: .normal)
            primaryButton.isEnabled = !selectedCandidates.isEmpty
            statusLabel.text = nil
            countLabel.text = nil
            table.reloadData()

        case .importing:
            titleLabel.text = L10n.string("Settings_linkImport_importingTitle")
            // The list stays up, frozen: its checkmarks are the record of what
            // the user chose, and hiding it would leave the sheet's middle blank
            // with the bar stranded at the bottom.
            table.isHidden = false
            table.allowsSelection = false
            progressStack.isHidden = false
            secondaryButton.isHidden = true
            primaryButton.setTitle(L10n.string("Settings_linkImport_stopButton"), for: .normal)
            primaryButton.isEnabled = true

        case let .summary(summary):
            titleLabel.text = summary.wasCancelled
                ? L10n.string("Settings_linkImport_stoppedTitle") : L10n.string("Settings_linkImport_finishedTitle")
            table.isHidden = false
            table.allowsSelection = false
            progressStack.isHidden = true
            secondaryButton.isHidden = true
            primaryButton.setTitle(L10n.string("Common_done"), for: .normal)
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
        countLabel.text = L10n.string("Settings_linkImport_progressCount", done, total)
    }

    private func statusText(for progress: LinkImportRunner.Progress) -> String {
        if runner.isCancelled { return L10n.string("Settings_linkImport_finishingStartedStatus") }
        switch progress.phase {
        case .saving: return L10n.string("Settings_linkImport_savingStatus")
        case .fetching: return L10n.string("Settings_linkImport_downloadingStatus")
        case .unlocking: return L10n.string("Settings_linkImport_unlockingStatus")
        case .rescuing: return L10n.string("Settings_linkImport_rescuingStatus")
        case .done: return L10n.string("Settings_linkImport_doneStatus")
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
                L10n.string("Settings_linkImport_importedCount", imported),
                L10n.string("Settings_linkImport_importedSubtitle")
            ),
        ]
        if summary.recoverableFailures > 0 {
            let failures = summary.recoverableFailures
            lines.append((
                L10n.string("Settings_linkImport_failuresCount", failures),
                L10n.string("Settings_linkImport_failuresSubtitle")))
        }
        if summary.duplicates > 0 {
            let duplicates = summary.duplicates
            lines.append((
                L10n.string("Settings_linkImport_duplicatesCount", duplicates),
                L10n.string("Settings_linkImport_duplicatesSubtitle")))
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
            return L10n.string("Settings_linkImport_linksSectionHeader", count)
        case .archive:
            let count = archived.count
            return L10n.string("Settings_linkImport_archiveSectionHeader", count)
        case .result:
            return L10n.string("Settings_linkImport_resultSectionHeader")
        case .rejected:
            guard case let .summary(summary) = stage else { return nil }
            let count = summary.rejected.count
            return L10n.string("Settings_linkImport_notSavedSectionHeader", count)
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .links, .archive:
            // Once, under the last section, and only when the file couldn't tell
            // us about an archive.
            guard section == visibleSections.count - 1, !isStructured else { return nil }
            return L10n.string("Settings_linkImport_unstructuredFooter")
        case .result:
            guard case let .summary(summary) = stage, summary.wasCancelled else { return nil }
            return L10n.string("Settings_linkImport_cancelledFooter")
        case .rejected:
            return L10n.string("Settings_linkImport_rejectedFooter")
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
        let preview = previews.state(for: entry.urlString)
        content.text = Self.rowTitle(for: entry, preview: preview)
        content.textProperties.numberOfLines = 2
        content.secondaryText = Self.rowSubtitle(for: entry, preview: preview)
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
        // The thumbnail (and the spinner that stands in for it) go TRAILING, so
        // the leading selection circle keeps the place the thumb already knows.
        cell.accessoryView = accessoryView(for: preview)
        cell.accessibilityTraits = entry.isSelected ? [.button, .selected] : [.button]
        return cell
    }

    /// The row's trailing slot: the thumbnail once it lands, a horizon spinner
    /// while the preview is being fetched, and nothing at all otherwise — an
    /// unreachable page leaves the row exactly as it was rather than parking a
    /// broken-image placeholder in it.
    private func accessoryView(for state: LinkImportPreviewLoader.State) -> UIView? {
        switch state {
        case .loading:
            let spinner = HorizonSpinnerView(side: 20)
            spinner.startAnimating()
            return spinner
        case let .loaded(preview):
            guard let image = preview.image else { return nil }
            let size = LinkImportPreviewLoader.thumbnailSize
            let view = UIImageView(frame: CGRect(origin: .zero, size: size))
            view.image = image
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = 6
            view.layer.cornerCurve = .continuous
            view.isAccessibilityElement = false
            return view
        case .idle, .unavailable:
            return nil
        }
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

    // MARK: - The preview window

    /// The rolling window is exactly what the table says is on screen (plus its own
    /// prefetch lead), so nothing is fetched speculatively.
    func tableView(
        _ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath
    ) {
        previews.enterWindow(reviewURLStrings(at: [indexPath]))
    }

    func tableView(
        _ tableView: UITableView, didEndDisplaying cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        previews.leaveWindow(reviewURLStrings(at: [indexPath]))
    }

    /// The URLs of the review rows at these index paths, and nothing else: the
    /// summary stage's rows are not links to preview, and an index path can arrive
    /// for a table whose content has since been replaced.
    private func reviewURLStrings(at indexPaths: [IndexPath]) -> [String] {
        guard case .summary = stage else {
            return indexPaths.compactMap { indexPath in
                guard indexPath.section < visibleSections.count else { return nil }
                let rows = entries(for: visibleSections[indexPath.section])
                guard indexPath.row < rows.count else { return nil }
                return rows[indexPath.row].urlString
            }
        }
        return []
    }

    /// Re-renders the visible rows for one URL after its preview landed. Just those
    /// rows: a `reloadData` mid-scroll would fight the user's thumb, and the same
    /// URL can't be in both sections (the parser dedupes) but is cheap to look for
    /// in either.
    private func refreshRows(showing urlString: String) {
        guard case .review = stage, let visible = table.indexPathsForVisibleRows
        else { return }
        let affected = visible.filter { indexPath in
            reviewURLStrings(at: [indexPath]).first == urlString
        }
        guard !affected.isEmpty else { return }
        UIView.performWithoutAnimation {
            table.reloadRows(at: affected, with: .none)
        }
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

    /// The row's headline, best answer first: what the page calls itself, then the
    /// title the FILE carried (a Luna markdown export writes one), then the URL's
    /// own path. The last is always available, which is why a preview can arrive
    /// late — or never — without the row ever being blank.
    static func rowTitle(
        for entry: Entry, preview: LinkImportPreviewLoader.State
    ) -> String {
        if case let .loaded(loaded) = preview, let title = loaded.title, !title.isEmpty {
            return title
        }
        return entry.fileTitle ?? displayTitle(for: entry.urlString)
    }

    /// The row's second line: the publisher when the page names one, else the host.
    /// Either way the site is visible, so two links with the same headline are
    /// still tellable apart.
    static func rowSubtitle(
        for entry: Entry, preview: LinkImportPreviewLoader.State
    ) -> String? {
        if case let .loaded(loaded) = preview, let site = loaded.siteName, !site.isEmpty {
            return site
        }
        return displaySubtitle(for: entry.urlString)
    }

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
                return L10n.string("Settings_linkImport_rejectedForeignKindGeneric")
            }
            return L10n.string("Settings_linkImport_rejectedForeignKindNamed", owner.displayName)
        case .unusableURL:
            return L10n.string("Settings_linkImport_rejectedUnusableURL")
        }
    }
}

// MARK: - Prefetching

/// The table's own lead: rows just past the edge of the screen enter the window
/// early, so a steady scroll finds its titles already there — and a fast flick
/// hands them straight back through `cancelPrefetching`, which drops them from the
/// queue before they cost anything.
extension LinkImportSheetViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        previews.enterWindow(reviewURLStrings(at: indexPaths))
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        previews.leaveWindow(reviewURLStrings(at: indexPaths))
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


// MARK: - The preview loader's delegate

extension LinkImportSheetViewController: LinkImportPreviewLoaderDelegate {
    func previewLoaderDidChangeRow(forURLString urlString: String) {
        refreshRows(showing: urlString)
    }
}
