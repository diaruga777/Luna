//
//  PriceTrackingViewController.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaModels
import LunaShareSurface
import LunaStorage
import UIKit

/// The price editor as a SCREEN: a header bar, a way out, and — filling
/// everything between them — the one `ProductDetailViewController` the in-deck
/// product card is also made of.
///
/// This class used to be the other half of a split: its own product title, its
/// own grouped `UITableView` of sellers, its own graph slot and its own
/// threshold footer, none of which matched the card's. What survives here is
/// only what a screen has and a card does not.
///
/// The exit is decided by an explicit `PriceTrackingExitContext` (host + entry),
/// so the right control lands in the right context regardless of the view
/// hierarchy (see `LunaModels/PriceTrackingExitContext.swift`): in-app, a back
/// chevron in the screen's own header pops to the saves list; in an extension
/// there is nothing to pop to, so the header carries only the title and the exit
/// is the floating glass `ExtensionExitButton` every other Luna extension surface
/// shows — the content steps up to leave it its corner.
public final class PriceTrackingViewController: UIViewController, UIGestureRecognizerDelegate {

    /// How the screen was opened, mapped to a `PriceTrackingExitContext`.
    public enum Mode {
        /// Viewing/editing an already-saved tracker (in-app).
        case existing(itemID: UUID)
        /// Save-time, a brand-new product saved as its OWN new tracker.
        case creation(itemID: UUID, host: PriceTrackingHost)
        /// Save-time, the just-saved URL was merged as a seller into an EXISTING
        /// tracker. `addedStoreURLString` is flashed in the seller list.
        case merge(itemID: UUID, addedStoreURLString: String, host: PriceTrackingHost)

        var itemID: UUID {
            switch self {
            case .existing(let id), .creation(let id, _), .merge(let id, _, _): return id
            }
        }

        /// The pure host + entry decision model for this mode.
        var exitContext: PriceTrackingExitContext {
            switch self {
            case .existing:
                return PriceTrackingExitContext(host: .inApp, entry: .existing)
            case .creation(_, let host):
                return PriceTrackingExitContext(host: host, entry: .creation)
            case .merge(_, let url, let host):
                return PriceTrackingExitContext(host: host, entry: .merge(addedStoreURLString: url))
            }
        }

        /// The just-added seller URL to flash (merge only).
        var highlightedURLString: String? {
            if case .merge(_, let url, _) = self { return url }
            return nil
        }
    }

    private let mode: Mode
    private let detail: ProductDetailViewController
    /// In-content header in place of the nav bar (title + back).
    private let navHeader = NavHeaderBar()
    /// UIKit owns the navigation controller's normal interactive-pop delegate. Keep
    /// it so this screen can temporarily opt in without changing other screens.
    private weak var previousInteractivePopGestureDelegate: UIGestureRecognizerDelegate?

    private var exitContext: PriceTrackingExitContext { mode.exitContext }

    /// Told when the extension's exit button dismisses the editor, so the host can
    /// complete its request — see `PriceEditorScreenDelegate`. Weak, and it IS the
    /// host: the host presents this editor, so it already owns it. Nil in-app, where
    /// the back chevron just pops. Set by the extension host after construction.
    public weak var completionDelegate: (any PriceEditorScreenDelegate)?

    public convenience init(itemID: UUID, priceFetcher: PriceFetching = PriceFetcher()) {
        self.init(mode: .existing(itemID: itemID), priceFetcher: priceFetcher)
    }

    public init(
        mode: Mode, priceFetcher: PriceFetching = PriceFetcher(),
        addSellerHandoff: (any AddSellerHandoffHandling)? = nil
    ) {
        self.mode = mode
        self.detail = ProductDetailViewController(
            itemID: mode.itemID, priceFetcher: priceFetcher,
            highlightedURLString: mode.highlightedURLString,
            addSellerHandoff: addSellerHandoff)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.groupedBackground

        navHeader.title = L10n.string("PriceTracker_tracking_screenTitle")
        navHeader.mount(in: self)

        addChild(detail)
        detail.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(detail.view)
        detail.didMove(toParent: self)

        // Every band sits in one centred column rather than stretching: a
        // threshold slider a thousand points wide, or a seller name that far
        // from its price, is not a form any more. `ReadableColumn` also makes the
        // container a HARD ceiling — a long marketplace product title used to
        // out-argue a merely preferred full width and hang every band off both
        // edges of the share sheet.
        let column = ReadableColumn.install(in: view)
        let bottom = detail.view.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            detail.view.topAnchor.constraint(equalTo: navHeader.bottomAnchor, constant: 12),
            detail.view.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
            detail.view.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -16),
        ])
        installExitChrome(bottom: bottom)
    }

    /// Installs the ONE way out, from the pure `PriceTrackingExitContext` decision,
    /// and lands the content's bottom edge above whatever that turns out to be.
    ///
    /// In-app the editor was pushed, so the exit is a back chevron in the screen's
    /// own header and the content keeps the bottom safe area to itself. In an
    /// extension there is no stack to pop to and the exit is the floating glass
    /// circle every other Luna extension surface shows — so the header carries only
    /// the title, and the seller list stands the circle's corner down rather than
    /// running underneath it.
    private func installExitChrome(bottom: NSLayoutConstraint) {
        guard exitContext.leftButton == .done else {
            navHeader.setLeadingControls([
                NavHeaderBar.backButton(target: self, action: #selector(leftButtonTapped)),
            ])
            bottom.isActive = true
            return
        }
        let exitButton = ExtensionExitButton.make { [weak self] in self?.dismissOrPop() }
        // The circle is the fixed thing in this pair and the content is what
        // gives: without this it is a button with a default 250 hugging holding
        // up a seller list that would happily take the whole screen, and the
        // exit stretches into a 700pt lozenge.
        exitButton.setContentHuggingPriority(.required, for: .vertical)
        exitButton.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(exitButton)
        NSLayoutConstraint.activate([
            exitButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -ExtensionExitButton.edgeInset),
            exitButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -ExtensionExitButton.edgeInset),
            detail.view.bottomAnchor.constraint(equalTo: exitButton.topAnchor, constant: -12),
        ])
    }

    /// Installing a custom left button (the explicit Back/Done decision above)
    /// suppresses UIKit's interactive-pop recognizer by default. Restore it for the
    /// in-app pushed editor so the root saves list remains reachable by the normal
    /// left-edge swipe; extension-hosted editors still have no navigation stack.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // This screen draws its OWN in-content header (so it animates as part of the
        // Dot Matrix wipe). Keep the shared nav bar hidden while we're visible.
        navigationController?.setNavigationBarHidden(true, animated: false)
        detail.reload()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard exitContext.host == .inApp,
              let popGesture = navigationController?.interactivePopGestureRecognizer else { return }
        if popGesture.delegate !== self {
            previousInteractivePopGestureDelegate = popGesture.delegate
        }
        popGesture.delegate = self
        popGesture.isEnabled = true
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let popGesture = navigationController?.interactivePopGestureRecognizer,
              popGesture.delegate === self else { return }
        // Return ownership to UIKit before another screen becomes visible.
        popGesture.delegate = previousInteractivePopGestureDelegate
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === navigationController?.interactivePopGestureRecognizer else {
            return true
        }
        guard exitContext.host == .inApp,
              let navigationController,
              navigationController.viewControllers.count > 1 else { return false }
        // Do not begin a second interactive transition while the navigation
        // controller is already pushing or popping.
        return navigationController.transitionCoordinator == nil
    }

    // MARK: - Exit

    /// The in-app header's back chevron: pops back to the saves list. The tracker
    /// is already saved and every edit persists as it's made, so this just leaves
    /// the screen. (The extension's exit button calls `dismissOrPop` directly.)
    @objc public func leftButtonTapped() {
        dismissOrPop()
    }

    /// Leaves the screen whichever way it was shown: pop when pushed onto a nav stack
    /// (in-app), else hand off to the extension host (which completes the extension
    /// request), else dismiss the modal presentation. Always exits.
    private func dismissOrPop() {
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else if let completionDelegate {
            completionDelegate.priceEditorDidFinish(self)
        } else {
            dismiss(animated: true)
        }
    }
}
