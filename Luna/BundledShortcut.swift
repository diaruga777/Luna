//
//  BundledShortcut.swift
//  Luna
//

import UIKit

/// The signed Action Button shortcut shipped in the app bundle. Single source of
/// truth for its name (used both to load the resource and in the user-facing
/// setup copy) and for the share-sheet install flow that Settings and onboarding
/// both invoke.
enum BundledShortcut {

    /// The shortcut's name as it appears in the Shortcuts app and the Action
    /// Button picker after import. Must match the bundled `.shortcut` file's name.
    static let displayName = "Send To Luna"

    /// Presents the system share sheet to import the bundled shortcut into the
    /// Shortcuts app. (`shortcuts://import-workflow?url=` rejects local file URLs,
    /// so import stays share-sheet based.) No-op if the resource is missing.
    static func presentInstaller(from presenter: UIViewController, sourceView: UIView? = nil) {
        guard let bundled = Bundle.main.url(
            forResource: displayName, withExtension: "shortcut")
        else { return }
        let temporaryCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(displayName).shortcut")
        try? FileManager.default.removeItem(at: temporaryCopy)
        do {
            try FileManager.default.copyItem(at: bundled, to: temporaryCopy)
        } catch {
            return
        }
        UIApplication.shared.open(temporaryCopy)
    }
}
