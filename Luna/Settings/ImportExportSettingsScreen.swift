//
//  ImportExportSettingsScreen.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaSaves
import LunaSavesUI
import LunaStorage
import LunaURLClassification
import UIKit
import UniformTypeIdentifiers

/// Settings ▸ Import & Export: two buttons (`claudedocs/import-export.md`).
///
/// Export shares every link this app shows as one markdown file: a titled
/// bullet per link under a `## Links` heading and a `## Archive` heading, so
/// it reads on its own and still comes back with its archive intact. Import
/// opens the document picker, reads whatever was chosen — markdown, a
/// foreign CSV, any text with links in it — and hands what it found to the
/// review sheet.
final class ImportExportSettingsScreen: NavHeaderTableController {

    private enum Row: Int, CaseIterable {
        case export
        case importFile
    }

    private let store: SavesStore

    static func screenTitle() -> String { L10n.string("Settings_importExport_title") }

    init(store: SavesStore = .shared) {
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
        L10n.string("Settings_importExport_footer")
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = view.tintColor ?? .systemBlue
        switch Row(rawValue: indexPath.row) ?? .export {
        case .export:
            content.text = L10n.string("Settings_importExport_exportRow")
            content.image = UIImage(systemName: "square.and.arrow.up")
        case .importFile:
            content.text = L10n.string("Settings_importExport_importRow")
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
                title: L10n.string("Settings_importExport_nothingToExportTitle"),
                // Not "your list is empty": the store is shared, so a sibling
                // app's saves may well be in it — there is just nothing here that
                // belongs to this one.
                message: L10n.string("Settings_importExport_nothingToExportMessage"))
            return
        }
        guard let fileURL = try? LinkListExport.writeTemporaryFile(document) else {
            presentInfoAlert(
                title: L10n.string("Settings_importExport_exportFailedTitle"),
                message: L10n.string("Settings_importExport_exportFailedMessage"))
            return
        }
        LunaShareSheet.present(items: [fileURL], from: self, anchor: .view(sourceView))
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
                    title: L10n.string("Settings_importExport_noLinksFoundTitle"),
                    message: L10n.string("Settings_importExport_noLinksFoundMessage")))
            return
        }
        presentWhenClear(LinkImportSheetViewController(document: document))
    }

    /// Presents once nothing else is up.
    ///
    /// The document picker dismisses itself after handing over its result, so
    /// a plain `present` racing that animation is silently dropped: the user
    /// picks a file and nothing happens. This makes the review sheet's
    /// appearance unconditional.
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
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
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
                            title: L10n.string("Settings_importExport_readFailedTitle"),
                            message: L10n.string("Settings_importExport_readFailedMessage")))
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

    /// What the document picker offers. Markdown first, since that is what
    /// Luna writes, then the two named foreign cases, then `text`, their
    /// common supertype, which admits the `.opml`-ish files the scrape still
    /// reads. The explicit markdown type matters on top of `.text`: a file
    /// tagged `net.daringfireball.markdown` from another device is otherwise
    /// offered greyed out on some hosts, even though it conforms.
    static var importableTypes: [UTType] {
        [markdownType, .commaSeparatedText, .plainText, .text]
    }

    /// `net.daringfireball.markdown` when the system knows it — it has since
    /// iOS 14 — else plain text. Never nil, so the picker always has a type list.
    static var markdownType: UTType {
        UTType("net.daringfireball.markdown") ?? .plainText
    }

    /// Every link this app is responsible for, newest first, archive
    /// separated, each with its title when it has one.
    ///
    /// Scoped by `LunaApp.includes` on purpose: the store is shared by all
    /// four apps, and Luna Reader exporting the Downloader's videos would
    /// hand back a file whose own re-import it would then reject.
    static func document(for items: [SavedItem]) -> LinkListDocument {
        let mine = items.filter { LunaApp.current.includes($0) }
        let exportable = mine.filter { SavedItem.isWebPageURL($0.urlString) }
        return LinkListDocument(
            links: exportable.filter { !$0.isArchived }.map(\.urlString),
            archived: exportable.filter(\.isArchived).map(\.urlString),
            // A title is what makes the file readable to a person, and it saves the
            // review sheet a fetch when the file comes back.
            titles: Dictionary(
                exportable.compactMap { item in
                    item.title.map { (item.urlString, $0) }
                },
                uniquingKeysWith: { first, _ in first }),
            isStructured: true)
    }

    /// Writes the export as **markdown**, `.md`.
    ///
    /// Markdown, not a `section,url` CSV: AirDropping a `.csv` routes it
    /// straight into Notes, and what comes back out of Notes is text with no
    /// CSV in it, so every link would re-import as one flat list with the
    /// archive split gone. A markdown file is legible on arrival and its
    /// structure survives that round trip, because a heading and a bullet
    /// are still a heading and a bullet after a rich-text editor has had
    /// them (see `LinkListMarkdown`).
    static func writeTemporaryFile(
        _ document: LinkListDocument, now: Date = Date()
    ) throws -> URL {
        let markdown = LinkListMarkdown.encode(
            document, appName: LunaApp.current.displayName, exportedOn: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "\(LunaApp.current.exportFileBaseName)-\(formatter.string(from: now)).md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Decodes a picked file and parses it. nil only when the bytes can't be read
    /// as text at all.
    static func readDocument(at url: URL) -> LinkListDocument? {
        guard let data = try? Data(contentsOf: url), let text = decodeText(data) else { return nil }
        return LinkListFile.parse(text)
    }

    /// A file the user picked has no declared encoding. Tries UTF-8 first —
    /// everything Luna writes, and nearly everything else — then UTF-16 with
    /// either BOM, which is what a spreadsheet saving "Unicode text"
    /// produces, then Latin-1, which cannot fail, so a link-bearing file is
    /// never rejected outright over one bad byte.
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
        case .vault: return "Luna-Vault-Files"
        }
    }
}
