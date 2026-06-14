//
//  ReaderViewController.swift
//  Clip
//

import UIKit

/// Hosts the two reading modes for an article — the scrolling reader and the
/// RSVP reader — swapping them in place via the nav-bar toggle. Remembers the
/// last used mode per article and tracks opened/read state.
final class ReaderViewController: UIViewController {

    private let item: ReadingListItem
    private let content: ArticleContent
    private let store = ReadingListStore.shared
    private var mode: ReadingListItem.ReaderMode
    private var currentChild: UIViewController?

    init(item: ReadingListItem, content: ArticleContent,
         forceMode: ReadingListItem.ReaderMode? = nil) {
        self.item = item
        self.content = content
        self.mode = forceMode ?? item.lastReaderMode ?? .scroll
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        store.markReadState(.opened, for: item.id)
        showMode(mode, persist: mode != (item.lastReaderMode ?? .scroll))
    }

    // MARK: - Mode switching

    @objc private func toggleMode() {
        showMode(mode == .scroll ? .rsvp : .scroll, persist: true)
    }

    private func showMode(_ newMode: ReadingListItem.ReaderMode, persist: Bool) {
        mode = newMode
        if persist {
            store.setReaderMode(newMode, for: item.id)
        }

        if let old = currentChild {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        let child: UIViewController
        switch newMode {
        case .scroll:
            let scroll = ScrollReaderViewController(item: item, content: content)
            scroll.onFinishedReading = { [weak self] in self?.markRead() }
            child = scroll
            view.backgroundColor = .systemBackground
        case .rsvp:
            let rsvp = RSVPViewController(item: item, content: content)
            rsvp.onFinishedReading = { [weak self] in self?.markRead() }
            child = rsvp
            view.backgroundColor = .systemBackground
        }

        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
        currentChild = child

        let icon = newMode == .scroll ? "bolt.fill" : "text.alignleft"
        let toggleItem = UIBarButtonItem(
            image: UIImage(systemName: icon), style: .plain,
            target: self, action: #selector(toggleMode))
        // Documents have no URL to share with friends or via the share sheet.
        let shareItem: UIBarButtonItem? = item.isDocument ? nil : UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"), style: .plain,
            target: self, action: #selector(shareTapped))
        if newMode == .rsvp {
            let settingsItem = UIBarButtonItem(
                image: UIImage(systemName: "gearshape"), style: .plain,
                target: self, action: #selector(openSettings))
            navigationItem.rightBarButtonItems = [toggleItem, settingsItem, shareItem].compactMap { $0 }
        } else {
            navigationItem.rightBarButtonItems = [toggleItem, shareItem].compactMap { $0 }
        }
    }

    @objc private func shareTapped() {
        SendToFriendSheet.present(
            from: self, sourceView: view,
            urlString: item.urlString, title: item.title ?? content.title)
    }

    @objc private func openSettings() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    private func markRead() {
        store.markReadState(.read, for: item.id)
    }
}
