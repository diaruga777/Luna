//
//  SavedMediaViewerViewController.swift
//  Luna
//
//  Photos-style saved-media viewer: a UIPageViewController paging horizontally
//  through the grid's items, one page per item, with the system iOS 18 zoom
//  transition zooming in from (and back out to) the grid cell instead of the
//  Dot Matrix pixel-wipe (see DotMatrixTransitionExempt).
//

import AVKit
import LunaMediaDownload
import LunaStorage
import LunaTransitions
import UIKit

/// A page hosted by the viewer's `UIPageViewController`, identified by the saved
/// media item it displays (not by index — indices shift as items are deleted).
private protocol SavedMediaPage: AnyObject {
    var itemID: UUID { get }
}

final class SavedMediaViewerViewController: UIViewController, DotMatrixTransitionExempt {
    private weak var grid: SavedMediaGridViewController?
    private var items: [SavedMediaItem]
    private var currentIndex: Int

    private let pageViewController = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [.interPageSpacing: 40])

    init(items: [SavedMediaItem], initialIndex: Int, grid: SavedMediaGridViewController) {
        self.items = items
        self.currentIndex = initialIndex
        self.grid = grid
        super.init(nibName: nil, bundle: nil)
        // iOS 18 zoom transition: zooms in from (and, on pop, back out to) the grid
        // cell of whichever item is CURRENTLY displayed — not necessarily the one the
        // user originally tapped, since they may have paged elsewhere in the interim.
        // DotMatrixTransitionExempt makes the nav delegate step aside so this (and its
        // built-in interactive dismiss) runs instead of the pixel-wipe.
        preferredTransition = .zoom { [weak self] _ in
            guard let self, self.items.indices.contains(self.currentIndex) else { return nil }
            return self.grid?.gridCellView(for: self.items[self.currentIndex].id)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .trash,
            target: self,
            action: #selector(deleteCurrent))

        pageViewController.dataSource = self
        pageViewController.delegate = self
        addChild(pageViewController)
        pageViewController.view.frame = view.bounds
        pageViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageViewController.view)
        pageViewController.didMove(toParent: self)

        // Mutations from ANY surface (this viewer's own trash button, the grid's
        // context menu, or another process via the Darwin bridge) route through the
        // same store notifications — refresh whenever either fires.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaChanged), name: .savedMediaChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaChanged), name: .readingListChanged, object: nil)

        guard items.indices.contains(currentIndex) else {
            navigationController?.popViewController(animated: false)
            return
        }
        let item = items[currentIndex]
        title = item.title ?? item.sourceURLString
        let page = makePage(for: item)
        pageViewController.setViewControllers([page], direction: .forward, animated: false)
        (page as? SavedMediaVideoPageViewController)?.player?.play()
        markOpened(item)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The grid hides the shared nav bar and draws its own header; un-hide it here
        // so the viewer's title + trash button show, matching the grid's own toggle in
        // its viewWillAppear (both run under the zoom transition's push/pop).
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func makePage(for item: SavedMediaItem) -> UIViewController & SavedMediaPage {
        switch item.kind {
        case .video: return SavedMediaVideoPageViewController(item: item)
        case .image, .gif: return SavedMediaImagePageViewController(item: item)
        }
    }

    private func markOpened(_ item: SavedMediaItem) {
        if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
            ReadingListStore.shared.markReadState(.opened, for: saved.id)
        }
    }

    @objc private func deleteCurrent() {
        guard items.indices.contains(currentIndex) else { return }
        let item = items[currentIndex]
        // NotificationCenter posts are synchronous, so the store's `.savedMediaChanged`
        // (or `.readingListChanged`, for the ReadingListStore-owned path) fires
        // `handleMediaChanged()` before this call returns — reusing the exact same
        // "current item vanished" handling as an external/cross-process deletion, so
        // deleting removes the page, advances to the next item, and pops only when
        // nothing is left, Photos-style, from one code path.
        if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
            ReadingListStore.shared.delete(saved)
        } else {
            SavedMediaStore.shared.delete(item)
        }
    }

    @objc private func handleMediaChanged() {
        let updated = SavedMediaStore.shared.items()
        let currentID = items.indices.contains(currentIndex) ? items[currentIndex].id : nil
        items = updated

        guard !items.isEmpty else {
            navigationController?.popViewController(animated: true)
            return
        }
        if let currentID, items.contains(where: { $0.id == currentID }) {
            return // Current item is still here — nothing to move, just kept `items` fresh.
        }

        // The current item vanished (deleted here or elsewhere): show the next
        // available item at the same (clamped) position, like Photos does.
        currentIndex = min(currentIndex, items.count - 1)
        let item = items[currentIndex]
        title = item.title ?? item.sourceURLString
        let page = makePage(for: item)
        pageViewController.setViewControllers([page], direction: .forward, animated: true)
        (page as? SavedMediaVideoPageViewController)?.player?.play()
        markOpened(item)
    }
}

extension SavedMediaViewerViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? SavedMediaPage,
              let idx = items.firstIndex(where: { $0.id == page.itemID }),
              idx > 0
        else { return nil }
        return makePage(for: items[idx - 1])
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? SavedMediaPage,
              let idx = items.firstIndex(where: { $0.id == page.itemID }),
              idx + 1 < items.count
        else { return nil }
        return makePage(for: items[idx + 1])
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed else { return }
        // Pause on page-away.
        if let previousVideo = previousViewControllers.first as? SavedMediaVideoPageViewController {
            previousVideo.player?.pause()
        }
        guard let current = pageViewController.viewControllers?.first as? SavedMediaPage,
              let idx = items.firstIndex(where: { $0.id == current.itemID })
        else { return }
        currentIndex = idx
        let item = items[idx]
        title = item.title ?? item.sourceURLString
        (current as? SavedMediaVideoPageViewController)?.player?.play()
        markOpened(item)
    }
}

/// A video page — plain `AVPlayerViewController` with autoplay, matching the previous
/// viewer's behavior.
private final class SavedMediaVideoPageViewController: AVPlayerViewController, SavedMediaPage {
    let itemID: UUID

    init(item: SavedMediaItem) {
        self.itemID = item.id
        super.init(nibName: nil, bundle: nil)
        player = AVPlayer(url: item.fileURL)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// An image/GIF page: a zoomable scroll view (double-tap to zoom, like Photos — kept
/// simple: min 1x, max ~4x). Loosely cribbed from LunaReaderUI's ImageLightboxViewController.
private final class SavedMediaImagePageViewController: UIViewController, UIScrollViewDelegate, SavedMediaPage {
    let itemID: UUID
    private let fileURL: URL
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(item: SavedMediaItem) {
        self.itemID = item.id
        self.fileURL = item.fileURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        imageView.image = UIImage(contentsOfFile: fileURL.path)
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        layoutImageViewToFit()

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        if scrollView.zoomScale <= scrollView.minimumZoomScale {
            layoutImageViewToFit()
        }
    }

    private func layoutImageViewToFit() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
            imageView.frame = scrollView.bounds
            return
        }
        let bounds = scrollView.bounds
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        centerImageView()
    }

    private func centerImageView() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImageView() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let target = 2.5
            let point = gesture.location(in: imageView)
            let width = scrollView.bounds.width / target
            let height = scrollView.bounds.height / target
            scrollView.zoom(
                to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                animated: true)
        }
    }
}
