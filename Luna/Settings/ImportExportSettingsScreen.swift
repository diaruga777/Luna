//
//  ImportExportSettingsScreen.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import LunaURLClassification
import UIKit
import UniformTypeIdentifiers

/// Settings ▸ Import & Export: two buttons (`claudedocs/import-export.md`).
///
/// Export shares every link this app shows as one `section,url` CSV, with the
/// archive as its own section so it comes back as an archive. Import opens the
/// document picker, reads whatever was chosen, and hands what it found to the
/// review sheet.
final class ImportExportSettingsScreen: NavHeaderTableController {

    private enum Row: Int, CaseIterable {
        case export
        case importFile
    }

    private let store: ReadingListStore

    static func screenTitle() -> String { L10n.string("Import & Export") }

    init(store: ReadingListStore = .shared) {
        self.store = store
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = Self.screenTitle()
        super.viewDidLoad()
    }

    // MARK: - Table

    override func numberOfSections(in _: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection _: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(
        _ tableView: UITableView, titleForFooterInSection _: Int
    ) -> String? {
        L10n.string(
            "Export writes every saved link, with the archive kept as its own list. Import reads a Luna export, another app's CSV, or any text file with links in it — you choose which ones to keep before anything is saved.")
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = view.tintColor ?? .systemBlue
        switch Row(rawValue: indexPath.row) ?? .export {
        case .export:
            content.text = L10n.string("Export Links")
            content.image = UIImage(systemName: "square.and.arrow.up")
        case .importFile:
            content.text = L10n.string("Import Links")
            content.image = UIImage(systemName: "square.and.arrow.down")
        }
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = indexPath.row == Row.export.rawValue
            ? "importExport.export" : "importExport.import"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let sourceView: UIView = tableView.cellForRow(at: indexPath) ?? tableView
        switch Row(rawValue: indexPath.row) ?? .export {
        case .export: presentExport(from: sourceView)
        case .importFile: presentImportPicker()
        }
    }

    // MARK: - Export

    private func presentExport(from sourceView: UIView) {
        let document = LinkListExport.document(for: store.items())
        guard !document.isEmpty else {
            presentInfoAlert(
                title: L10n.string("Nothing to Export"),
                // Not "your list is empty": the store is shared, so a sibling
                // app's saves may well be in it — there is just nothing here that
                // belongs to this one.
                message: L10n.string("There are no links in this app's list to export yet."))
            return
        }
        guard let fileURL = try? LinkListExport.writeTemporaryFile(document) else {
            presentInfoAlert(
                title: L10n.string("Couldn't Export Links"),
                message: L10n.string("The export file couldn't be written. Try again."))
            return
        }
        let activity = UIActivityViewController(
            activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView
        present(activity, animated: true)
    }

    // MARK: - Import

    private func presentImportPicker() {
        // `asCopy` so the picked file is readable without coordinating against a
        // security-scoped original that may live in another app's container.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: LinkListExport.importableTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentReview(for document: LinkListDocument) {
        guard !document.isEmpty else {
            presentWhenClear(
                infoAlert(
                    title: L10n.string("No Links Found"),
                    message: L10n.string("That file didn't contain any links Luna could read.")))
            return
        }
        presentWhenClear(LinkImportSheetViewController(document: document))
    }

    /// Presents once nothing else is up.
    ///
    /// The document picker dismisses ITSELF after handing over its result, so a
    /// plain `present` racing that animation is silently dropped — the user picks
    /// a file and nothing happens. This makes the review sheet's appearance
    /// unconditional.
    private func presentWhenClear(_ viewController: UIViewController) {
        guard let presented = presentedViewController else {
            present(viewController, animated: true)
            return
        }
        presented.dismiss(animated: false) { [weak self] in
            self?.present(viewController, animated: true)
        }
    }

    private func infoAlert(title: String, message: String) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
        return alert
    }
}

// MARK: - Document picker

extension ImportExportSettingsScreen: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else { return }
        // Read off the main thread: a big export is megabytes, and the picker's
        // dismissal shouldn't wait on the disk.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = LinkListExport.readDocument(at: url)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let document else {
                    self.presentWhenClear(
                        self.infoAlert(
                            title: L10n.string("Couldn't Read That File"),
                            message: L10n.string(
                                "Luna couldn't open it as text. Pick a CSV or plain-text file.")))
                    return
                }
                self.presentReview(for: document)
            }
        }
    }
}

/// The file end of import/export: which item is a link worth exporting, how the
/// file is named, and how bytes of unknown encoding become text.
enum LinkListExport {

    /// What the document picker offers. `commaSeparatedText` and `plainText`
    /// cover the two named cases; `text` is their common supertype and admits the
    /// `.md`/`.opml`-ish files that conform to it, which the scrape still reads.
    static var importableTypes: [UTType] {
        [.commaSeparatedText, .plainText, .text]
    }

    /// Every link THIS app is responsible for, newest first, archive separated.
    ///
    /// Scoped by `LunaApp.includes` on purpose: the store is shared by all four
    /// apps, and Luna Reader exporting the Downloader's videos would hand back a
    /// file whose own re-import it would then reject.
    static func document(for items: [ReadingListItem]) -> LinkListDocument {
        let mine = items.filter { LunaApp.current.includes($0) }
        return LinkListDocument(
            links: mine.filter { !$0.isArchived }.compactMap(exportedURL),
            archived: mine.filter(\.isArchived).compactMap(exportedURL),
            isStructured: true)
    }

    /// Synthetic URLs (`lunamail://`, `lunadoc://`) name bytes inside one
    /// device's container, so they are not links and are left out.
    private static func exportedURL(_ item: ReadingListItem) -> String? {
        ReadingListItem.isWebPageURL(item.urlString) ? item.urlString : nil
    }

    static func writeTemporaryFile(
        _ document: LinkListDocument, now: Date = Date()
    ) throws -> URL {
        let csv = LinkListCSV.encode(links: document.links, archived: document.archived)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "\(LunaApp.current.exportFileBaseName)-\(formatter.string(from: now)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data(csv.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Decodes a picked file and parses it. nil only when the bytes can't be read
    /// as text at all.
    static func readDocument(at url: URL) -> LinkListDocument? {
        guard let data = try? Data(contentsOf: url), let text = decodeText(data) else { return nil }
        return LinkListCSV.parse(text)
    }

    /// A file the user picked has no declared encoding. UTF-8 first (everything
    /// Luna writes, and nearly everything else), then UTF-16 with either BOM,
    /// which is what a spreadsheet saving "Unicode text" produces, then Latin-1,
    /// which cannot fail and so guarantees a link-bearing file is never rejected
    /// outright over one bad byte.
    static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(data: data, encoding: .isoLatin1)
    }
}

private extension LunaApp {
    /// The leading part of an export's filename. Not localized: it's a filename
    /// that travels between devices and apps.
    var exportFileBaseName: String {
        switch self {
        case .luna: return "Luna-Links"
        case .reader: return "Luna-Reader-Links"
        case .downloader: return "Luna-Downloader-Links"
        case .priceTracker: return "Luna-Price-Tracker-Links"
        }
    }
}
