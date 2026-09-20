//
//  ExtensionRecoveryFileIntake.swift
//  LunaShareSurface
//

import Foundation
import LunaIngest
import LunaModels
import LunaStorage

/// The extensions' half of the Luna file intake seam: a recovery file shared
/// into the share or action extension becomes a save right there, without the
/// user opening Luna (`claudedocs/luna-file.md`).
///
/// Two things differ from the app. The extension links no rescue engine, so the
/// file's recipe cannot be replayed here — it is kept for the app to learn a
/// host rule from. And the save is written and shown through
/// `ShareSurfaceDriver`, so the user sees the ordinary saved surface for that
/// kind rather than a second, recovery-shaped one.
@MainActor
public final class ExtensionRecoveryFileIntake: LunaRecoveryFileHandling {

    public init() {}

    public func handleRecovery(_ file: LunaRecoveryFile, sourceURL: URL?) {
        guard let host = ShareViewController.activeSurface else { return }
        if let recipe = file.recipe {
            PendingRecoveryRecipeStore.shared.append(PendingRecoveryRecipe(
                pageURL: file.url, recipe: recipe, dateWritten: Date()))
        }
        Task { @MainActor in
            guard let outcome = await RecoveryContentAdoption.outcome(for: file) else {
                host.failOrComplete(L10n.string("LunaFile_recoveryNotAdoptedMessage"))
                return
            }
            if let record = LLMHandoffStore.shared.record(forURL: file.url.absoluteString) {
                LLMHandoffStore.shared.clear(id: record.id)
            }
            // The driver persists against an existing row. A file shared
            // straight into the extension has none — the save it recovers was
            // made on another surface, or never made at all.
            let store = SavesStore.shared
            if store.item(forURLString: file.url.absoluteString) == nil {
                _ = store.reserveSaveAttempt(
                    urlString: file.url.absoluteString, source: .shareSheet, at: Date())
            }
            ShareSurfaceDriver(host: host, store: store).present(outcome, url: file.url)
        }
    }
}
