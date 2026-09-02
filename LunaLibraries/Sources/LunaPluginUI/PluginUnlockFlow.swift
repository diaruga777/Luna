//
//  PluginUnlockFlow.swift
//  LunaPluginUI
//

import LunaModels
import LunaSavesUI
import LunaStorage
import UIKit

/// The app's half of the browser lock (`claudedocs/plans/plugin-platform.md`
/// §8.3).
///
/// Two things reach it: a tap on a locked card of any kind, and the launch or
/// foreground sweep for a save whose browser step was answered but never
/// consumed. Both end the same way — the result is written against the save and
/// the pipeline runs again with the same id, so the plugin's Model replaces the
/// placeholder instead of adding a second row.
@MainActor
public enum PluginUnlockFlow {

    /// The installed witness. Holding one instance keeps the modal's legs alive
    /// for the length of a presentation.
    public static let shared = PluginUnlockFlowRunner()

    /// Presents the browser step `item` is waiting on. A save with no stored
    /// request has nothing to show, so nothing happens.
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

    public init(
        store: SavesStore = .shared, requests: PluginBrowserRequestStore = .shared,
        pageMaker: (any PluginBrowserPageMaking)? = nil
    ) {
        self.store = store
        self.requests = requests
        self.modal = PluginBrowserModalPresentation(pageMaker: pageMaker)
    }

    public func present(for item: SavedItem, from presenter: UIViewController) {
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
