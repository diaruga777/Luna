import Foundation
import LunaModels

/// The user-visible copy this tier writes into the library: the two system
/// group names, the fallback document title, and the first-run Welcome sheet.
/// Every other string in Luna Writer belongs to a UI tier.
enum L10nWriterStorage {
    static var inboxGroupName: String { L10n.string("WriterStorage_inboxGroupName") }
    static var trashGroupName: String { L10n.string("WriterStorage_trashGroupName") }
    static var untitledDocumentTitle: String { L10n.string("WriterStorage_untitledDocumentTitle") }
    static var welcomeSheetTitle: String { L10n.string("WriterStorage_welcomeSheetTitle") }
    static var welcomeSheetBody: String { L10n.string("WriterStorage_welcomeSheetBody") }
}
