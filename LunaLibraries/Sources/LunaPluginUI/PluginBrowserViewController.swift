//
//  PluginBrowserViewController.swift
//  LunaPluginUI
//

import LunaArchiveReader
import LunaDesignSystem
import LunaModels
import UIKit

/// Who takes the browser step's outcome.
@MainActor
public protocol PluginBrowserViewControllerDelegate: AnyObject {
    /// The step finished. `result` is nil when the user cancelled, the page
    /// answered `error`, or the step ran out of time.
    func pluginBrowser(
        _ controller: PluginBrowserViewController, didFinishWith result: PluginBrowserResult?)
    /// The escape hatch: hand the page to the system browser.
    func pluginBrowser(
        _ controller: PluginBrowserViewController, openInSystemBrowser url: URL)
}

/// A plugin's browser step: a live page under an opaque cover, uncovered only
/// while the page says it needs the user (`claudedocs/plans/plugin-platform.md`
/// §8.3).
///
/// The plugin's `detect` source is the whole of the stage machine. Luna runs it
/// every `DOMProbePoller.interval` and acts on the one word it answers:
/// `challenge` lifts the cover so the user can solve whatever is up, `done`
/// captures the page and closes, `error` stops with a message, and anything
/// else — including a page that answered nothing — keeps waiting under the
/// cover. A step that never answers ends at the request's own timeout.
@MainActor
public final class PluginBrowserViewController: UIViewController, DOMProbePollerDelegate {

    /// What one probe answered.
    public enum Stage: String {
        case wait, challenge, done, error
    }

    public weak var delegate: PluginBrowserViewControllerDelegate?

    private let request: PluginBrowserRequest
    private let page: any PluginBrowserPageDriving
    private let poller: DOMProbePoller
    private let cover: ChallengeCoverView
    private let clock: () -> Date
    private var deadline: Date?
    private var isProbing = false
    private var isCapturing = false
    /// Set once nothing may drive the page again — captured, refused, out of
    /// time, or over. It stops the cover being moved by a probe still in flight.
    private var didStop = false
    /// Set once the delegate has been told what the step produced. A dead end
    /// stops the page without answering, so the two are not the same flag.
    private var didAnswer = false

    /// - Parameters:
    ///   - page: the live page, from a `PluginBrowserPageMaking`.
    ///   - poller: the tick. A test drives `tickNow()` and never starts it.
    ///   - clock: reads the current time, for the timeout.
    public init(
        request: PluginBrowserRequest,
        title: String,
        page: any PluginBrowserPageDriving,
        poller: DOMProbePoller = DOMProbePoller(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.request = request
        self.page = page
        self.poller = poller
        self.clock = clock
        cover = ChallengeCoverView(
            actionTitle: L10n.string("Common_openInSafari"), actionSymbol: "safari")
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = request.title ?? title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        let pageView = page.pageView
        pageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: view.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        cover.cover(view)
        cover.label.setTextImmediately(L10n.string("PluginBrowser_workingStatus"))
        cover.actionButton.addAction(
            UIAction { [weak self] _ in self?.escapeToSystemBrowser() }, for: .touchUpInside)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.finish(with: nil) })
        navigationItem.leftBarButtonItem?.accessibilityLabel = L10n.string("Common_cancel")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "safari"),
            primaryAction: UIAction { [weak self] _ in self?.escapeToSystemBrowser() })

        deadline = clock().addingTimeInterval(request.timeout)
        page.load(request)
        poller.delegate = self
        poller.start()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        poller.stop()
        // Going away without an answer is a cancel — the sheet pulled down, or
        // a dead end whose message the person read and left. Either way the
        // plugin is still waiting, and without this it would sit out its whole
        // idle budget before the runtime abandoned it.
        guard !didAnswer else { return }
        finish(with: nil)
    }

    // MARK: - The stage machine

    public func probePollerDidTick(_ poller: DOMProbePoller) {
        guard !didStop else { return }
        if let deadline, clock() >= deadline {
            stop(with: L10n.string("PluginBrowser_timedOutMessage"))
            return
        }
        // One probe at a time. `evaluateJavaScript` on a busy page can outlast
        // the interval, and two in flight would fight over the cover.
        guard !isProbing, !isCapturing else { return }
        isProbing = true
        page.probe(request.detect) { [weak self] answer in
            guard let self else { return }
            self.isProbing = false
            self.apply(Stage(rawValue: answer ?? "") ?? .wait)
        }
    }

    private func apply(_ stage: Stage) {
        guard !didStop else { return }
        switch stage {
        case .wait:
            cover.isHidden = false
        case .challenge:
            // The one state the page is the user's business. Everything else
            // Luna does behind the cover.
            cover.isHidden = true
        case .done:
            isCapturing = true
            // WebKit can stop answering while collecting HTML or cookies.
            // Keep ticking until capture answers, with at most ten seconds
            // left to collect it (and never extend the request's deadline).
            let captureDeadline = clock().addingTimeInterval(10)
            deadline = min(deadline ?? captureDeadline, captureDeadline)
            page.capture { [weak self] result in
                guard let self, !self.didStop else { return }
                self.finish(with: result)
            }
        case .error:
            stop(with: L10n.string("PluginBrowser_failedMessage"))
        }
    }

    /// A dead end: the cover comes back with a message and the Safari escape,
    /// and nothing drives the page again.
    private func stop(with message: String) {
        guard !didStop else { return }
        didStop = true
        poller.stop()
        page.stopLoading()
        view.bringSubviewToFront(cover)
        cover.isHidden = false
        cover.spinner.stopAnimating()
        cover.label.setTextImmediately(message)
        cover.label.textColor = LunaColors.primaryText
        cover.actionButton.isHidden = false
    }

    private func escapeToSystemBrowser() {
        delegate?.pluginBrowser(self, openInSystemBrowser: page.currentURL ?? request.url)
    }

    private func finish(with result: PluginBrowserResult?) {
        guard !didAnswer else { return }
        didAnswer = true
        didStop = true
        poller.stop()
        page.stopLoading()
        delegate?.pluginBrowser(self, didFinishWith: result)
    }
}
