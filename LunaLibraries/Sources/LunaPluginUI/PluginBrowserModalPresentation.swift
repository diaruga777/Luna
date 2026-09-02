//
//  PluginBrowserModalPresentation.swift
//  LunaPluginUI
//

import LunaModels
import UIKit

/// Presents a plugin's browser step in one navigation-wrapped modal and
/// reports the outcome exactly once, however the presentation ends.
///
/// `ModalPluginBrowserPresenter` (a live `luna.browser.open` call) and
/// `PluginUnlockFlowRunner` (a locked card's tap) both build the same modal
/// around `PluginBrowserViewController` and only differ in what they do with
/// the result — resume a continuation, or write `PluginBrowserRequestStore`
/// and resume the ingest walk — so this type owns present/dismiss/delegate
/// and leaves that difference to the `onFinish` witness each call passes in.
@MainActor
final class PluginBrowserModalPresentation: NSObject, PluginBrowserViewControllerDelegate {

    private let pageMaker: any PluginBrowserPageMaking
    private weak var navigation: UINavigationController?
    private var onFinish: ((PluginBrowserResult?) -> Void)?

    init(pageMaker: (any PluginBrowserPageMaking)? = nil) {
        self.pageMaker = pageMaker ?? WebKitPluginBrowserPageMaker()
    }

    /// True while a step is already on screen. The caller checks this before
    /// `present` so a second request queues behind the answer to the first
    /// rather than opening a second modal over it.
    var isPresented: Bool { onFinish != nil }

    func present(
        _ request: PluginBrowserRequest, from presenter: UIViewController,
        onFinish: @escaping (PluginBrowserResult?) -> Void
    ) {
        self.onFinish = onFinish
        let browser = PluginBrowserViewController(
            request: request, title: L10n.string("PluginBrowser_defaultTitle"),
            page: pageMaker.makePage(for: request))
        browser.delegate = self
        let navigation = UINavigationController(rootViewController: browser)
        self.navigation = navigation
        presenter.present(navigation, animated: true)
    }

    func pluginBrowser(
        _ controller: PluginBrowserViewController, didFinishWith result: PluginBrowserResult?
    ) {
        navigation?.dismiss(animated: true)
        navigation = nil
        let onFinish = self.onFinish
        self.onFinish = nil
        onFinish?(result)
    }

    func pluginBrowser(
        _ controller: PluginBrowserViewController, openInSystemBrowser url: URL
    ) {
        let onFinish = self.onFinish
        self.onFinish = nil
        navigation?.dismiss(animated: true) { UIApplication.shared.open(url) }
        navigation = nil
        onFinish?(nil)
    }
}
