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
    /// Whether the accessory bar earns its space on this root. Defaults to
    /// iOS's width-plus-hardware-keyboard rule.
    public var accessoryBarPolicy: AccessoryBarPolicy
    public init(
        noteIndex: NoteIndexing,
        noteStore: NoteStoring,
        marksStore: DocumentMarksStoring,
        settings: WriterSettings,
        aiAssistant: AIWritingAssisting? = nil,
        accessoryBarPolicy: AccessoryBarPolicy = DefaultAccessoryBarPolicy()
    ) {
        self.noteIndex = noteIndex
        self.noteStore = noteStore
        self.marksStore = marksStore
        self.settings = settings
        self.aiAssistant = aiAssistant
        self.accessoryBarPolicy = accessoryBarPolicy
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
