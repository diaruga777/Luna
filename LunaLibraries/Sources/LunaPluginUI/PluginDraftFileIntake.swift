//
//  PluginDraftFileIntake.swift
//  LunaPluginUI
//

import LunaDesignSystem
import LunaModels
import LunaPluginKit
import LunaStorage
import UIKit

/// Where a surface puts the review screen. The app pushes it on the deck's
/// navigation stack; an extension hosts it in its own view hierarchy, which is
/// the only place it can present anything.
@MainActor
public protocol PluginDraftReviewPresenting: AnyObject {
    func presentPluginDraftReview(_ screen: PluginDraftReviewViewController)
    /// Takes the screen away after Save or Discard.
    func dismissPluginDraftReview(_ screen: PluginDraftReviewViewController)
}

/// The plugin half of the Luna file intake (`claudedocs/luna-file.md`).
///
/// It turns an arriving draft into a review screen, wherever the file landed.
/// The hand-off record — written by whichever surface asked for the plugin —
/// carries the request's own words and the page to test against, so a draft
/// that comes back to a different process than the one that asked is still
/// reviewed against the right site.
public final class PluginDraftFileIntake: LunaPluginFileHandling {

    private let presenter: any PluginDraftReviewPresenting
    private let handoffStore: LLMHandoffStore
    private let launcher: any LLMLaunching

    public init(
        presenter: any PluginDraftReviewPresenting,
        handoffStore: LLMHandoffStore = .shared,
        launcher: any LLMLaunching
    ) {
        self.presenter = presenter
        self.handoffStore = handoffStore
        self.launcher = launcher
    }

    @MainActor
    public func handlePlugin(source: String, headerJSON: String) {
        guard let importer = PluginPlatformServices.importer else { return }
        let screen = PluginDraftReviewViewController(
            sourceText: source, origin: origin(), importer: importer,
            handoffStore: handoffStore, launcher: launcher)
        screen.delegate = self
        presenter.presentPluginDraftReview(screen)
    }

    private func origin() -> PluginDraftReviewViewController.Origin? {
        guard let record = handoffStore.pluginRecord(),
              case .plugin(let description, let host) = record.kind else { return nil }
        return PluginDraftReviewViewController.Origin(
            description: description,
            host: host ?? PluginCreateViewController.host(inDescription: description),
            targetURL: PluginCreateViewController.firstLink(inDescription: description),
            recordID: record.id)
    }
}

extension PluginDraftFileIntake: PluginDraftReviewDelegate {
    public func pluginDraftReviewDidInstall(_ controller: PluginDraftReviewViewController) {
        presenter.dismissPluginDraftReview(controller)
    }

    public func pluginDraftReviewDidDiscard(_ controller: PluginDraftReviewViewController) {
        presenter.dismissPluginDraftReview(controller)
    }
}
