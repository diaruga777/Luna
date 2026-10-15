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

    /// Save-scoped routing survives the JavaScript callback queue, where Swift
    /// task-local values do not. Keep cancelled entries until that retry unwinds
    /// so a late browser request cannot reopen a dismissed modal.
    static var unlocks: [UUID: PluginBrowserModalPresentation] = [:]

    private let pageMaker: any PluginBrowserPageMaking
    private weak var navigation: UINavigationController?
    private var browser: PluginBrowserViewController?
    private var ownsRetry = false
    private var cancelled = false
    private var onCancel: (() -> Void)?
    private var onFinish: ((PluginBrowserResult?) -> Void)?

    init(pageMaker: (any PluginBrowserPageMaking)? = nil) {
        self.pageMaker = pageMaker ?? WebKitPluginBrowserPageMaker()
    }

    /// True while a step is already on screen. The caller checks this before
    /// `present` so a second request queues behind the answer to the first
    /// rather than opening a second modal over it.
    var isPresented: Bool { ownsRetry || onFinish != nil }

    func prepare(from presenter: UIViewController, onCancel: @escaping () -> Void) {
        ownsRetry = true
        cancelled = false
        self.onCancel = onCancel
        let browser = PluginBrowserViewController(title: L10n.string("PluginBrowser_defaultTitle"))
        browser.delegate = self
        self.browser = browser
        let navigation = UINavigationController(rootViewController: browser)
        self.navigation = navigation
        presenter.present(navigation, animated: true)
    }

    func presentStep(_ request: PluginBrowserRequest) async -> PluginBrowserResult? {
        guard ownsRetry, !cancelled, onFinish == nil, let browser else { return nil }
        return await withCheckedContinuation { continuation in
            onFinish = { continuation.resume(returning: $0) }
            browser.start(request, page: pageMaker.makePage(for: request))
        }
    }

    func endRetry() {
        ownsRetry = false
        onCancel = nil
        close()
    }

    private func close() {
        let onFinish = self.onFinish
        self.onFinish = nil
        browser?.delegate = nil
        dismissNavigation()
        navigation = nil
        browser = nil
        onFinish?(nil)
    }

    private func dismissNavigation(completion: (() -> Void)? = nil) {
        guard let navigation else { completion?(); return }
        if navigation.isBeingPresented, let transition = navigation.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in
                navigation.dismiss(animated: true, completion: completion)
            }
        } else {
            navigation.dismiss(animated: true, completion: completion)
        }
    }

    func present(
        _ request: PluginBrowserRequest, from presenter: UIViewController,
        onFinish: @escaping (PluginBrowserResult?) -> Void
    ) {
        self.onFinish = onFinish
        let browser = PluginBrowserViewController(
            request: request, title: L10n.string("PluginBrowser_defaultTitle"),
            page: pageMaker.makePage(for: request))
        browser.delegate = self
        self.browser = browser
        let navigation = UINavigationController(rootViewController: browser)
        self.navigation = navigation
        presenter.present(navigation, animated: true)
    }

    func pluginBrowser(
        _ controller: PluginBrowserViewController, didFinishWith result: PluginBrowserResult?
    ) {
        let onFinish = self.onFinish
        self.onFinish = nil
        if ownsRetry, result != nil {
            browser?.waitForPipeline()
            onFinish?(result)
        } else {
            cancelled = true
            onCancel?()
            close()
            onFinish?(result)
        }
    }

    func pluginBrowser(
        _ controller: PluginBrowserViewController, openInSystemBrowser url: URL
    ) {
        cancelled = true
        onCancel?()
        browser?.delegate = nil
        dismissNavigation { UIApplication.shared.open(url) }
        navigation = nil
        close()
    }
}
