//
//  PhotoSearchRootViewController.swift
//  clipper
//

import UIKit

/// Root of the Photo Search experience. Hosts the search grid as the main page
/// and the model/index setup screen behind a toolbar button. On first launch
/// (no index yet) it routes straight to setup.
final class PhotoSearchRootViewController: UINavigationController {

    private let context: PhotoSearchContext
    private lazy var gridViewController = PhotoSearchGridViewController(context: context)
    private lazy var ingestObserver = ForegroundPhotoIngestObserver(context: context)

    init(context: PhotoSearchContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        gridViewController.onOpenSetup = { [weak self] in self?.openSetup() }
        gridViewController.onOpenApplets = { [weak self] in self?.openApplets() }
        viewControllers = [gridViewController]

        if (try? context.indexStore.load()) == nil {
            openSetup(animated: false)
        }

        // Process photos captured while the app is open against active applets.
        ingestObserver.start()
    }

    private func openApplets() {
        pushViewController(AppletListViewController(context: context), animated: true)
    }

    private func openSetup(animated: Bool = true) {
        let setup = PhotoSearchModelViewController(context: context)
        setup.onIndexReady = { [weak self] in
            self?.popToRootViewController(animated: true)
        }
        pushViewController(setup, animated: animated)
    }
}
