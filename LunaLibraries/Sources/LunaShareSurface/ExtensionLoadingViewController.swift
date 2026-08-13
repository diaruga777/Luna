//
//  ExtensionLoadingViewController.swift
//  LunaShareSurface
//

import LunaDesignSystem
import LunaModels
import UIKit

/// Told when the wait screen's header exit is tapped.
@MainActor
public protocol ExtensionLoadingExitDelegate: AnyObject {
    func extensionLoadingViewControllerDidExit(
        _ screen: ExtensionLoadingViewController)
}

/// The action extension's first frame: a spinner, rotating status copy, and a
/// header with the way out.
///
/// This screen is a real navigation root, not views placed on top of
/// `ShareViewController`. The header must exist from the first frame, so the
/// wait looks the same throughout — only the button inside it changes, from
/// an `xmark` while the outcome is unknown to a `checkmark` once something
/// saves.
///
/// The spinner and status copy come from `LoadingStatusLayout`, which the
/// archive reader's cover also uses. This keeps the handover between the two
/// screens from moving anything on screen.
public final class ExtensionLoadingViewController: UIViewController {

    private let spinner = HorizonSpinnerView(side: 36)
    private let statusLabel = EclipseBloomStatusLabel()
    private var articleLoadingStatus: ArticleLoadingStatusCycler?
    private let initialText: String
    /// The extension host owns this screen, so this reference stays weak.
    public weak var exitDelegate: (any ExtensionLoadingExitDelegate)?
    /// Built only when a terminal state actually asks for them, so the ordinary
    /// wait carries no extra views.
    private var iconView: UIImageView?
    private var detailLabel: UILabel?

    /// - Parameters:
    ///   - initialText: the first phrase; the cycler rotates its reassurance after.
    ///   - exitDelegate: told when the header's exit button is tapped.
    public init(initialText: String, exitDelegate: (any ExtensionLoadingExitDelegate)?) {
        self.initialText = initialText
        self.exitDelegate = exitDelegate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                exitDelegate?.extensionLoadingViewControllerDidExit(self)
            })
        navigationItem.leftBarButtonItem?.accessibilityLabel = L10n.string("Common_close")

        spinner.startAnimating()
        LoadingStatusLayout.install(spinner: spinner, label: statusLabel, in: view)

        articleLoadingStatus = ArticleLoadingStatusCycler(
            label: statusLabel, initialText: initialText)
        articleLoadingStatus?.start()
    }

    /// A terminal state: stop the wait and let the message stand. The header's
    /// exit button is already there, so this screen needs no floating close
    /// button of its own.
    ///
    /// - Parameters:
    ///   - symbolName: an SF Symbol that takes the stopped spinner's place, for a
    ///     state that has a shape worth naming (no connection, say) rather than
    ///     just a sentence.
    ///   - detail: a second, quieter line under the message.
    public func showTerminal(
        _ message: String,
        symbolName: String? = nil,
        detail: String? = nil
    ) {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
        statusLabel.textColor = LunaColors.primaryText
        statusLabel.setTextImmediately(message)
        if let symbolName { showIcon(named: symbolName) }
        if let detail { showDetail(detail) }
    }

    /// Identifies the terminal symbol so a test can assert a state was drawn,
    /// not just written, without matching an image by its contents.
    public static let terminalIconIdentifier = "extension.terminal.icon"

    /// Swaps the stopped spinner for a symbol in the same spot — the layout keeps
    /// its centre, so nothing above or below the icon moves.
    private func showIcon(named symbolName: String) {
        spinner.isHidden = true
        let icon = iconView ?? {
            let icon = UIImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentMode = .scaleAspectFit
            icon.tintColor = LunaColors.secondaryText
            icon.isAccessibilityElement = false
            icon.accessibilityIdentifier = Self.terminalIconIdentifier
            view.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: spinner.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            ])
            iconView = icon
            return icon
        }()
        icon.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 34, weight: .light))
    }

    private func showDetail(_ detail: String) {
        let label = detailLabel ?? {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = LunaColors.secondaryText
            label.textAlignment = .center
            label.numberOfLines = 0
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(
                    equalTo: statusLabel.bottomAnchor, constant: Self.detailSpacing),
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.leadingAnchor.constraint(
                    greaterThanOrEqualTo: view.leadingAnchor,
                    constant: LoadingStatusLayout.horizontalInset),
                label.trailingAnchor.constraint(
                    lessThanOrEqualTo: view.trailingAnchor,
                    constant: -LoadingStatusLayout.horizontalInset),
                label.widthAnchor.constraint(
                    lessThanOrEqualToConstant: LunaLayout.readableWidth),
            ])
            detailLabel = label
            return label
        }()
        label.text = detail
    }

    /// Gap between the terminal message and its quieter second line — tighter
    /// than the spinner's own `labelSpacing`, because the two lines are one
    /// thought.
    private static let detailSpacing: CGFloat = 8

    /// Stops the animation without changing the copy — for a handover to another
    /// screen that is about to replace this one.
    public func stopWaiting() {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
    }
}
