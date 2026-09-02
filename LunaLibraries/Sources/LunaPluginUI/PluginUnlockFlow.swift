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
public final class PluginUnlockFlowRunner: NSObject, PluginBrowserViewControllerDelegate,
    PluginLockedSavePresenting
{

    private let store: SavesStore
    private let requests: PluginBrowserRequestStore
    private weak var navigation: UINavigationController?
    private var presentedSaveID: UUID?

    public init(
        store: SavesStore = .shared, requests: PluginBrowserRequestStore = .shared
    ) {
        self.store = store
        self.requests = requests
    }

    public func present(for item: SavedItem, from presenter: UIViewController) {
        guard presentedSaveID == nil,
              let record = requests.pending(for: item.id),
              let request = PluginBrowserRequest(json: record.requestJSON)
        else { return }
        let browser = PluginBrowserViewController(
            request: request, title: L10n.string("PluginBrowser_defaultTitle"))
        browser.delegate = self
        let navigation = UINavigationController(rootViewController: browser)
        self.navigation = navigation
        presentedSaveID = item.id
        presenter.present(navigation, animated: true)
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

    public func pluginBrowser(
        _ controller: PluginBrowserViewController, didFinishWith result: PluginBrowserResult?
    ) {
        let saveID = presentedSaveID
        presentedSaveID = nil
        navigation?.dismiss(animated: true)
        navigation = nil
        guard let saveID, let result, let json = result.jsonText else { return }
        requests.complete(saveID: saveID, resultJSON: json)
        guard let resumer = PluginResumeSeams.resumer else { return }
        Task { await resumer.resumePluginLockedSave(id: saveID) }
    }

    public func pluginBrowser(
        _ controller: PluginBrowserViewController, openInSystemBrowser url: URL
    ) {
        presentedSaveID = nil
        navigation?.dismiss(animated: true) {
            UIApplication.shared.open(url)
        }
        navigation = nil
    }
}
