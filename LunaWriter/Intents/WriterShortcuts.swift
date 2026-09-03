//
//  WriterShortcuts.swift
//  LunaWriter
//

import AppIntents

/// Surfaces the Writer intents in Shortcuts, Spotlight and Siri. Phrases are
/// Siri grammar and stay literal (claudedocs/strings.md).
struct WriterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddWriterNoteIntent(),
            phrases: [
                "Add a note to \(.applicationName)",
                "Take a note in \(.applicationName)",
            ],
            shortTitle: "Add Note",
            systemImageName: "note.text.badge.plus"
        )
        AppShortcut(
            intent: CreateWriterDocumentIntent(),
            phrases: [
                "New sheet in \(.applicationName)",
            ],
            shortTitle: "New Sheet",
            systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: OpenWriterDocumentIntent(),
            phrases: [
                "Open a sheet in \(.applicationName)",
            ],
            shortTitle: "Open Sheet",
            systemImageName: "doc.text"
        )
    }
}
