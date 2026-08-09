//
//  PendingSaveCardContentViewController.swift
//  Luna
//
//  The one first frame for every saved URL while its kind and metadata are
//  still being resolved. Keeping it generic means a product or media URL never
//  briefly wears the reader's "Untitled" header before its own card arrives.
//

import LunaDesignSystem
import LunaModels
import UIKit

/// Metadata-free placeholder for a newly saved item.
///
/// A pending item has no trustworthy title, image, or source identity yet. The
/// card therefore says only that Luna is working; `KindDeckProvider` replaces
/// it on the first non-pending store update, when the kind-specific card has
/// real metadata to render.
final class PendingSaveCardContentViewController: CardContentViewController {

    private let spinner = HorizonSpinnerView(side: 36)
    private let statusLabel = EclipseBloomStatusLabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        spinner.startAnimating()
        statusLabel.setTextImmediately(L10n.string("Common_loadingEllipsis"))
        LoadingStatusLayout.install(spinner: spinner, label: statusLabel, in: view)
    }

    deinit { spinner.stopAnimating() }

    #if DEBUG
    var loadingTextForTesting: String? { statusLabel.text }
    var isSpinnerAnimatingForTesting: Bool { spinner.isAnimating }
    #endif
}
