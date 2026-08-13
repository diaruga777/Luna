//
//  PresentingHostViewController.swift
//  Luna
//

#if DEBUG

import UIKit

// Moved here from `UITestScreen.swift`, which compiles only into the central
// app: staged mode needs the same helper in all four, and the deep-linked
// screen catalog and the stage catalogs both present modals over a host.

/// A container that shows `host` and, once it has appeared, presents a modal built
/// by `makeModal`. Used to deep-link to screens the app only ever shows modally over
/// another root (e.g. the nested split-web overlay). DEBUG-only test scaffolding.
final class PresentingHostViewController: UIViewController {
    private let host: UIViewController
    private let makeModal: @MainActor () -> UIViewController?
    /// Whether the presentation animates. Off by default — a capture wants the
    /// settled frame — but the nested split-web overlay's whole subject IS its
    /// transition, so that one opts in.
    private let animates: Bool
    private var hasPresented = false

    init(
        host: UIViewController, animates: Bool = false,
        makeModal: @escaping @MainActor () -> UIViewController?
    ) {
        self.host = host
        self.animates = animates
        self.makeModal = makeModal
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasPresented, let modal = makeModal() else { return }
        hasPresented = true
        if modal.modalPresentationStyle == .automatic {
            modal.modalPresentationStyle = .fullScreen
        }
        present(modal, animated: animates)
    }
}

#endif
