import Foundation
import LunaWriterModels

/// First run: the two system groups exist by then, so all this adds is one
/// sheet that shows what the app does.
///
/// The test is "no sheets at all", not a defaults flag. A writer who empties
/// their library gets the Welcome sheet back, and a library restored from
/// files does not get a second one.
public enum LibraryBootstrap {
    @discardableResult
    public static func run(
        library: WriterLibraryStoring, textStore: DocumentTextStoring
    ) throws -> WriterDocument? {
        let existing = try library.documents(matching: FilterPredicate(), scope: nil)
        guard existing.isEmpty else { return nil }
        // A writer who trashed every sheet without emptying the Trash still
        // has a library, just an empty-looking one — the Welcome sheet is
        // for a library that has never held anything at all.
        let trashed = try library.documents(in: library.trashGroupID, sort: .createdDescending)
        guard trashed.isEmpty else { return nil }
        var document = try library.createDocument(
            in: library.inboxGroupID, title: L10nWriterStorage.welcomeSheetTitle)
        try textStore.saveText(L10nWriterStorage.welcomeSheetBody, for: &document)
        return document
    }
}
