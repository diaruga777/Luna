//
//  PluginUnlockFlow.swift
//  LunaPluginUI
//

import LunaArchiveReader
import LunaModels
import LunaSavesUI
import LunaStorage
import UIKit

/// The app's half of the browser lock (`claudedocs/plans/plugin-platform.md`
/// §8.3).
///
/// Two things reach it: a tap on a locked card of any kind, and the launch or
/// foreground sweep for a save whose browser step was answered but never
/// consumed. Both run the current pipeline with the same id, so the plugin's
/// Model replaces the placeholder instead of adding a second row. A tap retries
/// silent extraction before asking the current plugin for a browser step.
@MainActor
public enum PluginUnlockFlow {

    /// The installed witness. Holding one instance keeps the modal's legs alive
    /// for the length of a presentation.
    public static let shared = PluginUnlockFlowRunner()

    /// Retries `item` with the current plugins. A browser is presented only if
    /// the current ingest walk still needs one.
    public static func present(for item: SavedItem, from presenter: UIViewController) {
        shared.present(for: item, from: presenter)
    }

    /// Re-runs every plugin-locked save whose browser step already has an
    /// answer. Called at launch and on foreground: a step finished in one
    /// session can be consumed in the next.
    public static func resumeCompleted() {
        shared.resumeCompleted()
    }
}

/// The unlock flow's state: which save is on screen, and the modal's legs.
///
/// A class rather than the enum above, because a presentation lives until the
/// user or the page ends it and something has to hold the delegate.
@MainActor
public final class PluginUnlockFlowRunner: PluginBrowserViewControllerDelegate,
    PluginLockedSavePresenting
{

    private let store: SavesStore
    private let requests: PluginBrowserRequestStore
    private let modal: PluginBrowserModalPresentation
    private var retrying = Set<UUID>()

    public init(
        store: SavesStore = .shared, requests: PluginBrowserRequestStore = .shared,
        pageMaker: (any PluginBrowserPageMaking)? = nil
    ) {
        self.store = store
        self.requests = requests
        self.modal = PluginBrowserModalPresentation(pageMaker: pageMaker)
    }

    public func present(for item: SavedItem, from presenter: UIViewController) {
        // Deferred requests contain executable detection/cleanup scripts from
        // the attempt that failed. Replaying them first bypasses fixes in the
        // installed plugin (and its now-successful silent extraction). Re-enter
        // the normal app walk, which also consumes any completed browser answer
        // and asks its live browser bridge for a fresh step only when necessary.
        if let resumer = PluginResumeSeams.resumer {
            guard retrying.insert(item.id).inserted else { return }
            // Install feedback synchronously, before the first network probe.
            // The live browser may appear above this cover; it stays until the
            // whole attempt ends, including extraction after a browser answer.
            let cover = ChallengeCoverView(
                actionTitle: L10n.string("Common_cancel"), actionSymbol: "xmark")
            cover.accessibilityIdentifier = "PluginUnlockProgress"
            cover.label.setTextImmediately(L10n.string("PluginBrowser_workingStatus"))
            cover.cover(presenter.view)
            Task { [self] in
                defer {
                    cover.removeFromSuperview()
                    retrying.remove(item.id)
                }
                await resumer.resumePluginLockedSave(id: item.id)
            }
            return
        }
        guard !modal.isPresented,
              let record = requests.pending(for: item.id),
              let request = PluginBrowserRequest(json: record.requestJSON)
        else { return }
        let saveID = item.id
        modal.present(request, from: presenter) { [weak self] result in
            guard let self, let result, let json = result.jsonText else { return }
            self.requests.complete(saveID: saveID, resultJSON: json)
            guard let resumer = PluginResumeSeams.resumer else { return }
            Task { await resumer.resumePluginLockedSave(id: saveID) }
        }
    }

    public func resumeCompleted() {
        // Older app versions could downgrade a cancelled unlock to a bookmark
        // while retaining its plugin owner. Restore the tappable lock on launch
        // and foreground without opening any browser unprompted.
        for item in store.items() where item.state == .link && item.pluginID != nil {
            store.markPluginLocked(item.id, pluginID: item.pluginID!, title: item.title)
        }
        let waiting = store.items()
            .filter { $0.isPluginLocked }
            .filter { requests.record(for: $0.id)?.resultJSON != nil }
        guard !waiting.isEmpty, let resumer = PluginResumeSeams.resumer else { return }
        for item in waiting {
            Task { await resumer.resumePluginLockedSave(id: item.id) }
        }
    }

    public func presentPluginUnlock(for item: SavedItem, from presenter: UIViewController) {
        present(for: item, from: presenter)
    }

    // MARK: - PluginBrowserViewControllerDelegate

    /// Forwards to the shared modal, which is the real delegate of every
    /// browser step this runner presents. Kept public so a test can drive a
    /// step to completion without a live probe/capture round trip.
    public func pluginBrowser(
        _ controller: PluginBrowserViewController, didFinishWith result: PluginBrowserResult?
    ) {
        modal.pluginBrowser(controller, didFinishWith: result)
    }

    public func pluginBrowser(
        _ controller: PluginBrowserViewController, openInSystemBrowser url: URL
    ) {
        modal.pluginBrowser(controller, openInSystemBrowser: url)
    }
}
