import UIKit
import LunaWriterModels
import LunaWriterStorage

/// The seam onto a real editor screen. `LunaWriterEditor` is built in a
/// parallel work package; this tier never imports it. The app's composition
/// root adapts the real editor to this protocol, and the stage catalog / unit
/// tests adapt a fake to it instead.
public protocol DocumentEditing: AnyObject {
    var editingDelegate: DocumentEditingDelegate? { get set }
    var document: WriterDocument { get }
    func focus(on anchor: TextAnchor)
    func flushPendingSave()
    /// Replaces the whole visible text, e.g. a snapshot restore. The editor's
    /// live buffer takes the new text so its next autosave cannot overwrite it
    /// with what was on screen before the replace.
    func replaceText(_ text: String)
    /// Presents the editor's own statistics surface (`StatisticsSheet`) over
    /// `presenter`, returning `true` when it did. Returning `false` — the
    /// default — tells the caller no such surface is reachable, so it falls
    /// back to its own summary rather than showing two different ones.
    func presentStatistics(from presenter: UIViewController) -> Bool
}

extension DocumentEditing {
    public func replaceText(_ text: String) {}
    public func presentStatistics(from presenter: UIViewController) -> Bool { false }
}

/// What an editor reports back to its container.
public protocol DocumentEditingDelegate: AnyObject {
    func editor(_ editor: DocumentEditing, didUpdate document: WriterDocument)
    func editorRequestsNotesPanel(_ editor: DocumentEditing)
}

/// Builds the concrete editor screen for a sheet. One production witness in
/// the app (wrapping `LunaWriterEditor`); a fake in tests.
public protocol DocumentEditorMaking: AnyObject {
    func makeEditor(for document: WriterDocument) -> UIViewController & DocumentEditing
}

/// Read-along's chip/HUD host over the editor. `nil` on a device with neither
/// gaze nor voice, so the container hosts nothing.
public protocol ReadAlongChromeProviding: AnyObject {
    func readAlongChrome(for editor: UIViewController & DocumentEditing) -> UIView?
    /// The sheet is closing: stop its camera, microphone and frame clock now
    /// rather than whenever the editor happens to deallocate.
    func tearDownReadAlong(for editor: UIViewController & DocumentEditing)
}

extension ReadAlongChromeProviding {
    public func tearDownReadAlong(for editor: UIViewController & DocumentEditing) {}
}

/// What the Settings screen's Read-along section asks the read-along tier for.
/// `nil` on a device with no TrueDepth camera and no microphone permission
/// path — the rows using it are hidden instead of shown disabled.
public protocol ReadAlongSettingsHandling: AnyObject {
    var gazeAvailable: Bool { get }
    var voiceAvailable: Bool { get }
    var lastCalibrationGrade: String? { get }
    func presentCalibration(from presenter: UIViewController)
}

/// Where the groups list sent the reader: a fixed library scope, a group, or
/// a saved filter.
public enum LibrarySelection: Hashable {
    case all
    case recent
    case favorites
    case inbox
    case trash
    case group(GroupID)
    case filter(FilterID)
}

/// Weak reference from `SheetsViewController` back to whatever hosts it.
public protocol GroupsSelectionDelegate: AnyObject {
    func groupsViewController(_ controller: GroupsViewController, didSelect selection: LibrarySelection)
    /// The sidebar's "New Document": `group` is the highlighted group, or
    /// `nil` for the Inbox. On a compact width the sidebar is the only
    /// column on screen, so this is the one way to start writing there.
    func groupsViewController(_ controller: GroupsViewController, requestsNewDocumentIn group: GroupID?)
}

/// Weak reference from `EditorContainerViewController` back to whatever
/// hosts it.
public protocol SheetsSelectionDelegate: AnyObject {
    func sheetsViewController(_ controller: SheetsViewController, didSelect document: WriterDocument)
}

/// What the root does when an open document stops being showable — trashed
/// through any path (the editor's own menu, a sheets-list swipe, or an
/// external reconciler run) or removed outright. The root resets its
/// secondary column to the empty placeholder rather than leaving a trashed
/// sheet's editor on screen.
public protocol LibraryNavigationHandling: AnyObject {
    func documentDidClose(_ id: DocumentID)
}

/// Every witness the organiser needs, bundled so a root view controller takes
/// one argument instead of eight.
public final class LibraryEnvironment {
    public let library: WriterLibraryStoring
    public let notes: NoteStoring
    public let marks: DocumentMarksStoring
    public let textStore: DocumentTextStoring
    public let snapshots: DocumentSnapshotStoring
    public let noteIndex: NoteIndexing
    public let settings: WriterSettings
    public let editorMaker: DocumentEditorMaking
    public let readAlongChrome: ReadAlongChromeProviding?
    public let readAlongSettings: ReadAlongSettingsHandling?
    /// Where sheets live on disk, for the Settings → Library row. `nil` in a
    /// test stack that never needs to show one.
    public let libraryRootPath: String?

    public init(
        library: WriterLibraryStoring,
        notes: NoteStoring,
        marks: DocumentMarksStoring,
        textStore: DocumentTextStoring,
        snapshots: DocumentSnapshotStoring,
        noteIndex: NoteIndexing,
        settings: WriterSettings,
        editorMaker: DocumentEditorMaking,
        readAlongChrome: ReadAlongChromeProviding? = nil,
        readAlongSettings: ReadAlongSettingsHandling? = nil,
        libraryRootPath: String? = nil
    ) {
        self.library = library
        self.notes = notes
        self.marks = marks
        self.textStore = textStore
        self.snapshots = snapshots
        self.noteIndex = noteIndex
        self.settings = settings
        self.editorMaker = editorMaker
        self.readAlongChrome = readAlongChrome
        self.readAlongSettings = readAlongSettings
        self.libraryRootPath = libraryRootPath
    }
}
