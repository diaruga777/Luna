//
//  ExtensionLoadingViewController.swift
//  LunaShareSurface
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The action extension's first frame: a spinner, rotating status copy, and a header
/// carrying the way out.
///
/// It is a real navigation root rather than views dropped onto `ShareViewController`
/// so the header exists from the FIRST frame. The extension used to show a bare
/// black sheet with a centred spinner and no bar at all, then — when the archive
/// reader took over as the navigation root — a bar would appear from nowhere partway
/// through the wait. One wait should look like one wait: the bar is there from the
/// start, and only the button inside it changes (an `xmark` while the outcome is
/// unknown, a `checkmark` once something has been saved).
///
/// The spinner + copy come from `LoadingStatusLayout`, which the archive reader's
/// cover also uses, so the handover between the two doesn't move anything.
public final class ExtensionLoadingViewController: UIViewController {

    private let spinner = HorizonSpinnerView(side: 36)
    private let statusLabel = EclipseBloomStatusLabel()
    private var articleLoadingStatus: ArticleLoadingStatusCycler?
    private let initialText: String
    private let onExit: () -> Void

    /// - Parameters:
    ///   - initialText: the first phrase; the cycler rotates its reassurance after.
    ///   - onExit: tapped the header's exit button.
    public init(initialText: String, onExit: @escaping () -> Void) {
        self.initialText = initialText
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.onExit() })
        navigationItem.leftBarButtonItem?.accessibilityLabel = L10n.string("Common_close")

        spinner.startAnimating()
        LoadingStatusLayout.install(spinner: spinner, label: statusLabel, in: view)

        articleLoadingStatus = ArticleLoadingStatusCycler(
            label: statusLabel, initialText: initialText)
        articleLoadingStatus?.start()
    }

    /// A terminal state: stop the wait and let the message stand. The header's exit
    /// button is already there, so there is nothing to reveal — which is why this
    /// screen needs no floating close button of its own.
    public func showTerminal(_ message: String) {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
        statusLabel.textColor = LunaColors.primaryText
        statusLabel.setTextImmediately(message)
    }

    /// Stops the animation without changing the copy — for a handover to another
    /// screen that is about to replace this one.
    public func stopWaiting() {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
    }
}
