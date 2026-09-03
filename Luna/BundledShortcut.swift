//
//  BundledShortcut.swift
//  Luna
//

import UIKit
import LunaModels
import LunaStorage

/// The signed Action Button shortcut shipped in the app bundle. Single source of
/// truth for its name (used both to load the resource and in the user-facing
/// setup copy) and for the share-sheet install flow Settings' Shortcut & Safari
/// screen invokes.
///
/// Each app ships its OWN signed shortcut, named after the app — the four live
/// side by side in `Luna/Resources/` and every app target excludes the other
/// three through a synchronized-group membership exception, so exactly one is
/// in any bundle. They have to be separate files: a shortcut's Save/Provide
/// Context actions name a specific app, and a device with two Luna apps
/// installed would otherwise have two identically named entries in the Action
/// Button picker.
enum BundledShortcut {

    /// The shortcut's name as it appears in the Shortcuts app and the Action
    /// Button picker after import. Must match the bundled `.shortcut` file's
    /// name — iOS names an imported signed shortcut after the file it came from.
    private static var resourceName: String {
        switch LunaApp.current {
        case .luna: return "Luna"
        case .reader: return "Luna Reader"
        case .downloader: return "Luna Video"
        case .priceTracker: return "Luna Price Tracker"
        case .vault: return "Luna Vault"
        case .writer: return "Luna Writer"
        }
    }

    /// Deliberately NOT an `L10n` lookup, and the one piece of user-visible text
    /// that isn't (`LunaApp.displayName` reads the same words out of the strings
    /// table, and is the wrong source here for exactly that reason). iOS takes
    /// this name from the imported `.shortcut` file, so the two have to agree;
    /// editing the copy on its own would rename the button in Luna's own prose
    /// while the Action Button picker went on showing the old name. Rename the
    /// bundled resource and this constant together, or neither.
    static var displayName: String { resourceName }

    /// Presents the system share sheet to import the bundled shortcut into the
    /// Shortcuts app. (`shortcuts://import-workflow?url=` rejects local file URLs,
    /// so import stays share-sheet based.) No-op if the resource is missing.
    static func presentInstaller(
        from presenter: UIViewController,
        sourceView: UIView? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        // The Shortcuts import sheet cannot report whether the user completed
        // Add Shortcut. The tap is the strongest honest signal available, so
        // retain it separately from the later per-app App Intent run evidence.
        LunaSetupStatusStore.shared.recordShortcutInstallPressed(for: .current)
        guard let bundled = Bundle.main.url(
            forResource: resourceName, withExtension: "shortcut")
        else {
            completion?(false)
            return
        }
        let temporaryCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(resourceName).shortcut")
        try? FileManager.default.removeItem(at: temporaryCopy)
        do {
            try FileManager.default.copyItem(at: bundled, to: temporaryCopy)
        } catch {
            completion?(false)
            return
        }
        UIApplication.shared.open(
            temporaryCopy,
            options: [:],
            completionHandler: completion)
    }
}

/// The central Luna product page used by faceted apps' returning-user setup
/// conversation. Keep the URL build-configured: the placeholder namespace can
/// be renamed, and App Store numeric IDs cannot be derived from a bundle ID.
enum LunaCoreAppStoreLink {
    static var url: URL? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "LunaCoreAppStoreURL") as? String,
              !value.isEmpty
        else { return nil }
        return URL(string: value)
    }
}
