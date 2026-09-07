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
import LunaStorage
import UIKit

/// Metadata-free placeholder for a newly saved item.
///
/// A pending item has no trustworthy title, image, or source identity yet. The
/// card therefore says only that Luna is working; `KindDeckProvider` replaces
/// it on the first non-pending store update, when the kind-specific card has
/// real metadata to render. A save that stays pending for a while — a
/// transcription — names its step through `PendingSaveStatus.provider`, and the
/// card re-reads that line on every store change.
final class PendingSaveCardContentViewController: CardContentViewController {
    private let itemID: UUID?
    private let spinner = HorizonSpinnerView(side: 36)
    private let statusLabel = EclipseBloomStatusLabel()
    private var changeObserver: NSObjectProtocol?

    init(itemID: UUID? = nil) {
        self.itemID = itemID
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        spinner.startAnimating()
        statusLabel.setTextImmediately(currentStatus())
        LoadingStatusLayout.install(spinner: spinner, label: statusLabel, in: view)
        if itemID != nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .savesChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatus() }
            }
        }
    }

    deinit {
        spinner.stopAnimating()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    private func currentStatus() -> String {
        if let itemID, let status = PendingSaveStatus.provider?.status(forSaveID: itemID) {
            return status
        }
        return L10n.string("Common_loadingEllipsis")
    }

    func refreshStatus() {
        let status = currentStatus()
        guard status != statusLabel.text else { return }
        statusLabel.setTextImmediately(status)
    }

    #if DEBUG
    var loadingTextForTesting: String? { statusLabel.text }
    var isSpinnerAnimatingForTesting: Bool { spinner.isAnimating }
    #endif
}
