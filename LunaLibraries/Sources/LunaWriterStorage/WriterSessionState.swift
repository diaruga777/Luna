import Foundation
import LunaWriterModels

/// Which library scope the sidebar was showing, in a form this tier can
/// store. `LunaWriterLibraryUI.LibrarySelection` is the organiser's own type
/// and converts to and from this one; the storage tier holds no view types.
public enum LibrarySelectionValue: Equatable, Sendable {
    case all
    case recent
    case notes
    case favorites
    case inbox
    case trash
    case group(GroupID)
    case filter(FilterID)

    /// The form written to defaults and read back.
    public var storageValue: String {
        switch self {
        case .all: return "all"
        case .recent: return "recent"
        case .notes: return "notes"
        case .favorites: return "favorites"
        case .inbox: return "inbox"
        case .trash: return "trash"
        case .group(let id): return "group:\(id.storageValue)"
        case .filter(let id): return "filter:\(id.storageValue)"
        }
    }

    /// An unreadable value gives nil, so the caller falls back to the whole
    /// library rather than inventing a group.
    public init?(storageValue: String) {
        switch storageValue {
        case "all": self = .all
        case "recent": self = .recent
        case "notes": self = .notes
        case "favorites": self = .favorites
        case "inbox": self = .inbox
        case "trash": self = .trash
        default:
            let parts = storageValue.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let raw = String(parts[1])
            switch parts[0] {
            case "group":
                guard let id = GroupID(storageValue: raw) else { return nil }
                self = .group(id)
            case "filter":
                guard let id = FilterID(storageValue: raw) else { return nil }
                self = .filter(id)
            default: return nil
            }
        }
    }
}

/// Where the caret rests in the open sheet and whether the keyboard is up.
/// Reported by the editor and restored into it.
public struct EditorEditingState: Equatable, Sendable {
    public var caretLocation: Int
    public var isKeyboardVisible: Bool

    public init(caretLocation: Int = 0, isKeyboardVisible: Bool = false) {
        self.caretLocation = caretLocation
        self.isKeyboardVisible = isKeyboardVisible
    }
}

/// The page Luna Writer was on, so the next launch reopens it.
///
/// Every value is small and written straight through to defaults, so a
/// caller records on each change rather than batching.
public final class WriterSessionState {

    /// The open sheet, the sidebar scope, and where the caret was in that
    /// sheet. `documentID` is nil when the writer was looking at a list.
    public struct Snapshot: Equatable, Sendable {
        public var documentID: DocumentID?
        public var selection: LibrarySelectionValue
        public var caretLocation: Int?
        public var keyboardVisible: Bool

        public init(
            documentID: DocumentID? = nil,
            selection: LibrarySelectionValue = .all,
            caretLocation: Int? = nil,
            keyboardVisible: Bool = false
        ) {
            self.documentID = documentID
            self.selection = selection
            self.caretLocation = caretLocation
            self.keyboardVisible = keyboardVisible
        }
    }

    private enum Key {
        static let document = "luna.writer.session.document"
        static let selection = "luna.writer.session.selection"
        static let caret = "luna.writer.session.caret"
        static let keyboard = "luna.writer.session.keyboard"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether anything was recorded yet. A first run has no page to return
    /// to, so the caller opens the Welcome sheet instead.
    public var hasSnapshot: Bool {
        defaults.object(forKey: Key.selection) != nil || defaults.object(forKey: Key.document) != nil
    }

    public var snapshot: Snapshot {
        get {
            Snapshot(
                documentID: defaults.string(forKey: Key.document).flatMap { DocumentID(storageValue: $0) },
                selection: defaults.string(forKey: Key.selection)
                    .flatMap { LibrarySelectionValue(storageValue: $0) } ?? .all,
                caretLocation: defaults.object(forKey: Key.caret) as? Int,
                keyboardVisible: defaults.bool(forKey: Key.keyboard))
        }
        set {
            write(newValue.documentID?.storageValue, Key.document)
            write(newValue.selection.storageValue, Key.selection)
            write(newValue.caretLocation, Key.caret)
            write(newValue.keyboardVisible, Key.keyboard)
        }
    }

    /// A different sheet is open, or none. The caret and keyboard belong to
    /// the sheet that was open, so they go with it.
    public func recordOpenDocument(_ id: DocumentID?) {
        guard id != snapshot.documentID else { return }
        write(id?.storageValue, Key.document)
        write(nil, Key.caret)
        write(false, Key.keyboard)
    }

    public func recordSelection(_ selection: LibrarySelectionValue) {
        write(selection.storageValue, Key.selection)
    }

    /// Records where the caret rests in `id`. A report from a sheet that is
    /// no longer the open one is dropped, so a closing editor cannot write
    /// its caret over the sheet that replaced it.
    public func recordEditingState(_ state: EditorEditingState, for id: DocumentID) {
        guard snapshot.documentID == id else { return }
        write(state.caretLocation, Key.caret)
        write(state.isKeyboardVisible, Key.keyboard)
    }

    public func clear() {
        for key in [Key.document, Key.selection, Key.caret, Key.keyboard] {
            defaults.removeObject(forKey: key)
        }
    }

    private func write(_ value: Any?, _ key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
