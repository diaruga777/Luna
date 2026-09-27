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
    /// Where the caret rests and whether the keyboard is up right now.
    var editingState: EditorEditingState { get }
    /// Puts the caret back where a previous run left it and raises the
    /// keyboard when it was up. Called before the editor appears.
    func restoreEditingState(_ state: EditorEditingState)
    /// Presents the editor's own statistics surface (`StatisticsSheet`) over
    /// `presenter`, returning `true` when it did. Returning `false` — the
    /// default — tells the caller no such surface is reachable, so it falls
    /// back to its own summary rather than showing two different ones.
    func presentStatistics(from presenter: UIViewController) -> Bool
}

extension DocumentEditing {
    public var editingState: EditorEditingState { EditorEditingState() }
    public func restoreEditingState(_ state: EditorEditingState) {}
    public func replaceText(_ text: String) {}
    public func presentStatistics(from presenter: UIViewController) -> Bool { false }
}

/// What an editor reports back to its container.
public protocol DocumentEditingDelegate: AnyObject {
    func editor(_ editor: DocumentEditing, didUpdate document: WriterDocument)
    func editorRequestsNotesPanel(_ editor: DocumentEditing)
    /// The caret came to rest somewhere new, or the keyboard went up or
    /// down. Reported at the caret's resting position, not per keystroke.
    func editor(_ editor: DocumentEditing, didChangeEditingState state: EditorEditingState)
    /// The chrome (nav header, read-along chip) should hide or show: typing
    /// began or ended, or the page reached its top.
    func editor(_ editor: DocumentEditing, wantsChromeHidden hidden: Bool)
    /// A double tap on blank space: flip whatever the chrome is doing now.
    func editorDidRequestChromeToggle(_ editor: DocumentEditing)
    /// The editor made another sheet the writer should now be in — the
    /// next chapter — and asks its host to open it.
    func editor(_ editor: DocumentEditing, requestsOpening document: WriterDocument)
}

extension DocumentEditingDelegate {
    public func editor(_ editor: DocumentEditing, didChangeEditingState state: EditorEditingState) {}
    public func editor(_ editor: DocumentEditing, wantsChromeHidden hidden: Bool) {}
    public func editorDidRequestChromeToggle(_ editor: DocumentEditing) {}
    public func editor(_ editor: DocumentEditing, requestsOpening document: WriterDocument) {}
}

/// Opens a sheet in the editor column. The root implements it; an editor
/// container asks it when its editor made a new chapter.
public protocol DocumentOpening: AnyObject {
    func openDocument(_ document: WriterDocument)
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
    case notes
    case favorites
    case inbox
    case trash
    case group(GroupID)
    case filter(FilterID)
}

extension LibrarySelection {
    /// The storage tier's mirror of this scope, for the session snapshot.
    public var storedValue: LibrarySelectionValue {
        switch self {
        case .all: return .all
        case .recent: return .recent
        case .notes: return .notes
        case .favorites: return .favorites
        case .inbox: return .inbox
        case .trash: return .trash
        case .group(let id): return .group(id)
        case .filter(let id): return .filter(id)
        }
    }

    public init(_ stored: LibrarySelectionValue) {
        switch stored {
        case .all: self = .all
        case .recent: self = .recent
        case .notes: self = .notes
        case .favorites: self = .all
        case .inbox: self = .all
        case .trash: self = .trash
        case .group(let id): self = .group(id)
        case .filter(let id): self = .filter(id)
        }
    }
}

/// Weak reference from `SheetsViewController` back to whatever hosts it.
public protocol GroupsSelectionDelegate: AnyObject {
    func groupsViewController(_ controller: GroupsViewController, didSelect selection: LibrarySelection)
    /// The sidebar's "New Document": `group` is the highlighted group, or
    /// `nil` for the Inbox. On a compact width the sidebar is the only
    /// column on screen, so this is the one way to start writing there.
    func groupsViewController(_ controller: GroupsViewController, requestsNewDocumentIn group: GroupID?)
    /// The sidebar's gear. Settings has no other on-screen entry: the ⌘,
    /// command and the Mac menu need a keyboard.
    func groupsViewControllerRequestsSettings(_ controller: GroupsViewController)
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
    /// The page to reopen on the next launch, recorded as the writer moves.
    public let sessionState: WriterSessionState
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
        sessionState: WriterSessionState,
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
        self.sessionState = sessionState
        self.editorMaker = editorMaker
        self.readAlongChrome = readAlongChrome
        self.readAlongSettings = readAlongSettings
        self.libraryRootPath = libraryRootPath
    }
}
