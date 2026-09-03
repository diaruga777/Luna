//
//  EditorEnvironment.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterStorage

/// The witnesses one editor needs, gathered in one value so the organiser
/// hands them over in a single argument.
public struct EditorEnvironment {

    public var noteIndex: NoteIndexing
    public var noteStore: NoteStoring
    public var marksStore: DocumentMarksStoring
    public var settings: WriterSettings
    /// nil where no on-device model exists, which is most devices.
    public var aiAssistant: AIWritingAssisting?

    public init(
        noteIndex: NoteIndexing,
        noteStore: NoteStoring,
        marksStore: DocumentMarksStoring,
        settings: WriterSettings,
        aiAssistant: AIWritingAssisting? = nil
    ) {
        self.noteIndex = noteIndex
        self.noteStore = noteStore
        self.marksStore = marksStore
        self.settings = settings
        self.aiAssistant = aiAssistant
    }
}

/// A view that lets every touch through to what is under it.
///
/// The read-along band and HUD are drawn over the text and must never take a
/// touch the writer meant for a word.
public final class PassthroughView: UIView {
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
