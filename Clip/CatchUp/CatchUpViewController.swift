//
//  CatchUpViewController.swift
//  Clip
//

import UIKit

/// A Slack-style "catch up" experience over the reading list's UNREAD items. Each
/// unread item is a swipeable card: drag left to **Bump** (re-sort to the top with a
/// new bump date) or right to **Mark Read** (same actions on the bottom buttons).
/// Article cards embed a live reader (scroll mode, mode switcher, scrollable);
/// media/link cards show the row preview and open on tap. After the last card, an
/// optional "Delete all read?" screen, then an "All done!" screen with Undo.
final class CatchUpViewController: UIViewController {

    private enum Phase { case cards, deletePrompt, done }

    private let store = ReadingListStore.shared
    private weak var router: ReadingListViewController?

    /// Whole-list snapshot taken at entry; "Undo" restores it in one shot.
    private let snapshot: [ReadingListItem]
    private var queue: [ReadingListItem]
    private var index = 0
    /// Read-item ids the user chose to delete on the prompt screen; applied on Done
    /// (deferred so Undo can revert it).
    private var pendingDeleteIDs: [UUID] = []
    private var deleteReadView: CatchUpDeleteReadView?
    private var phase: Phase = .cards

    private let titleLabel = UILabel()
    private let leftButton = UIButton(type: .system)
    private let rightButton = UIButton(type: .system)
    private let cardArea = UIView()
    private let messageView = CatchUpMessageView()
    private let primaryButton = UIButton(type: .system)    // Bump / Keep
    private let secondaryButton = UIButton(type: .system)  // Mark Read / Delete All / Done

    private var currentCard: CatchUpCardView?
    private var currentReaderChild: UIViewController?
    private var currentItem: ReadingListItem? {
        index < queue.count ? queue[index] : nil
    }

    /// - Parameter unread: the unread items to catch up, in display order.
    init(unread: [ReadingListItem], router: ReadingListViewController) {
        self.snapshot = ReadingListStore.shared.items()
        self.queue = unread
        self.router = router
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureBackground()
        configureBars()
        configureCardArea()
        configureBottomButtons()
        addSimulatorSwipeHookIfNeeded()
        if queue.isEmpty {
            advanceToEndScreens()
        } else {
            showCard()
            updateChrome()
        }
    }

    /// Simulator-only: a tiny "Sim Swipe" button that holds the current card at a
    /// partial left swipe, so the rotated state can be inspected (the harness can't
    /// drag). Never shown on device.
    private func addSimulatorSwipeHookIfNeeded() {
        guard AppEnvironment.isSimulator else { return }
        let button = UIButton(type: .system)
        button.setTitle("Sim Swipe", for: .normal)
        button.accessibilityLabel = "Sim Swipe"
        button.titleLabel?.font = .systemFont(ofSize: 11)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.topAnchor.constraint(equalTo: leftButton.bottomAnchor),
        ])
        button.addAction(UIAction { [weak self] _ in
            self?.currentCard?.simulatorHoldSwipe(fraction: 0.45)
        }, for: .touchUpInside)
    }

    // MARK: - Layout

    private func configureBackground() {
        // An off-color backdrop the glass cards read against: a lighter gray in dark
        // mode (so the near-black cards aren't black-on-black), grouped gray in light.
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.17, alpha: 1)
                : .systemGroupedBackground
        }
    }

    private func configureBars() {
        leftButton.tintColor = GlassStyle.readingAccent
        leftButton.addTarget(self, action: #selector(leftTapped), for: .touchUpInside)
        leftButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(leftButton)

        rightButton.tintColor = GlassStyle.readingAccent
        rightButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        rightButton.addTarget(self, action: #selector(rightTapped), for: .touchUpInside)
        rightButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rightButton)

        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            leftButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            leftButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            leftButton.widthAnchor.constraint(equalToConstant: 44),
            leftButton.heightAnchor.constraint(equalToConstant: 44),
            rightButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            rightButton.centerYAnchor.constraint(equalTo: leftButton.centerYAnchor),
            rightButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: leftButton.centerYAnchor),
        ])
    }

    private func configureCardArea() {
        cardArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardArea)

        messageView.translatesAutoresizingMaskIntoConstraints = false
        messageView.isHidden = true
        view.addSubview(messageView)

        NSLayoutConstraint.activate([
            cardArea.topAnchor.constraint(equalTo: leftButton.bottomAnchor, constant: 12),
            cardArea.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            cardArea.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            messageView.topAnchor.constraint(equalTo: cardArea.topAnchor),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            messageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func configureBottomButtons() {
        for button in [primaryButton, secondaryButton] {
            button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
            button.layer.cornerRadius = 16
            button.layer.cornerCurve = .continuous
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 58).isActive = true
            view.addSubview(button)
        }
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            primaryButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            primaryButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            secondaryButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            secondaryButton.bottomAnchor.constraint(equalTo: primaryButton.bottomAnchor),
            secondaryButton.leadingAnchor.constraint(equalTo: primaryButton.trailingAnchor, constant: 12),
            primaryButton.widthAnchor.constraint(equalTo: secondaryButton.widthAnchor),
            cardArea.bottomAnchor.constraint(equalTo: primaryButton.topAnchor, constant: -16),
        ])
    }

    // MARK: - Cards

    private func showCard() {
        guard let item = currentItem else { advanceToEndScreens(); return }
        let card = CatchUpCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.onAction = { [weak self] action in self?.commitAction(action) }
        cardArea.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: cardArea.topAnchor),
            card.bottomAnchor.constraint(equalTo: cardArea.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: cardArea.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: cardArea.trailingAnchor),
        ])
        currentCard = card
        populate(card, with: item)
    }

    private func populate(_ card: CatchUpCardView, with item: ReadingListItem) {
        let header = CatchUpCardHeader(item: item)
        header.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
        ])

        let body: UIView
        if ReadingListViewController.rendersAsReader(item), item.state == .ready,
           let content = store.content(for: item) {
            // Embed the reader DIRECTLY (no UINavigationController) with an inline
            // liquid-glass header. The card rasterizes itself while rotating, so the
            // glass header + audio button render at identity scale and never balloon.
            let reader = ReaderViewController(
                item: item, content: content, forceMode: .scroll,
                shareProvider: nil, gazeTrackerFactory: nil,
                persistsModePreference: false, marksOpenedOnLoad: false,
                inlineControlsHeader: true)
            addChild(reader)
            body = reader.view
            currentReaderChild = reader
            defer { reader.didMove(toParent: self) }
        } else {
            body = CatchUpMediaCardBody(item: item, store: store) { [weak self] in
                self?.openMediaItem(item)
            }
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor),
        ])
    }

    /// Opens a media/link card's item from the catch-up screen, then marks it read.
    private func openMediaItem(_ item: ReadingListItem) {
        router?.openItem(item, presentingFrom: self)
        store.markReadState(.read, for: item.id)
    }

    private func commitAction(_ action: CatchUpCardView.Action) {
        guard let item = currentItem else { return }
        switch action {
        case .bump: store.bump(item.id)
        case .markRead: store.markReadState(.read, for: item.id)
        }
        tearDownCurrentCard()
        index += 1
        if currentItem != nil {
            showCard()
            updateChrome()
        } else {
            advanceToEndScreens()
        }
    }

    private func tearDownCurrentCard() {
        if let reader = currentReaderChild {
            reader.willMove(toParent: nil)
            reader.view.removeFromSuperview()
            reader.removeFromParent()
            currentReaderChild = nil
        }
        currentCard?.removeFromSuperview()
        currentCard = nil
    }

    // MARK: - End screens

    private func advanceToEndScreens() {
        tearDownCurrentCard()
        let readItems = store.items().filter { $0.readState == .read }
        if phase == .cards, !readItems.isEmpty {
            phase = .deletePrompt
            let prompt = CatchUpDeleteReadView(items: readItems, store: store)
            prompt.updateTitle(allSelected: true)
            prompt.onSelectionChanged = { [weak self] selected, total in
                self?.updateDeleteButton(selected: selected, total: total)
            }
            prompt.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(prompt)
            NSLayoutConstraint.activate([
                prompt.topAnchor.constraint(equalTo: leftButton.bottomAnchor, constant: 8),
                prompt.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                prompt.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                prompt.bottomAnchor.constraint(equalTo: primaryButton.topAnchor, constant: -16),
            ])
            deleteReadView = prompt
        } else {
            phase = .done
            messageView.show(symbol: "checkmark.circle.fill", tint: GlassStyle.readingAccent, text: "All done!")
            messageView.isHidden = false
        }
        updateChrome()
    }

    /// Flips the delete button (and the prompt title) between "Delete All" and
    /// "Delete Selected", disabling it when nothing is selected.
    private func updateDeleteButton(selected: Int, total: Int) {
        let allSelected = selected == total
        styleButton(
            secondaryButton, title: allSelected ? "Delete All" : "Delete Selected",
            filled: true, destructive: true)
        secondaryButton.isEnabled = selected > 0
    }

    // MARK: - Chrome (per phase)

    private func updateChrome() {
        secondaryButton.isEnabled = true   // reset (delete-prompt may disable it)
        switch phase {
        case .cards:
            titleLabel.text = "\(queue.count - index) left"
            leftButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
            rightButton.setTitle(nil, for: .normal)
            rightButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
            rightButton.isHidden = false
            styleButton(primaryButton, title: "Bump", filled: false)
            styleButton(secondaryButton, title: "Mark Read", filled: true)
            setBottomButtons(hidden: false, singleFullWidth: false)
        case .deletePrompt:
            titleLabel.text = nil   // the prompt view carries its own title
            leftButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            rightButton.isHidden = true
            styleButton(primaryButton, title: "Keep", filled: false)
            styleButton(secondaryButton, title: "Delete All", filled: true, destructive: true)
            setBottomButtons(hidden: false, singleFullWidth: false)
        case .done:
            titleLabel.text = nil
            leftButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            rightButton.setImage(nil, for: .normal)
            rightButton.setTitle("Undo", for: .normal)
            rightButton.isHidden = false
            styleButton(secondaryButton, title: "Done", filled: true)
            setBottomButtons(hidden: false, singleFullWidth: true)
        }
    }

    private func styleButton(_ button: UIButton, title: String, filled: Bool, destructive: Bool = false) {
        // Primary actions: filled accent (or red for destructive). Secondary: a
        // tinted-accent glass pill — the app's liquid-glass button language.
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        let accent = destructive ? UIColor.systemRed : GlassStyle.readingAccent
        config.baseBackgroundColor = accent
        config.baseForegroundColor = filled ? .white : accent
        config.cornerStyle = .large
        button.configuration = config
    }

    /// On the done screen the single button spans full width (primary hidden).
    private func setBottomButtons(hidden: Bool, singleFullWidth: Bool) {
        primaryButton.isHidden = hidden || singleFullWidth
        secondaryButton.isHidden = hidden
        primaryLeadingToSecondary?.isActive = !singleFullWidth
        secondaryLeadingToView?.isActive = singleFullWidth
    }
    private lazy var primaryLeadingToSecondary: NSLayoutConstraint? =
        secondaryButton.leadingAnchor.constraint(equalTo: primaryButton.trailingAnchor, constant: 12)
    private lazy var secondaryLeadingToView: NSLayoutConstraint? =
        secondaryButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16)

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch phase {
        case .cards: currentCard?.performAction(.bump)
        case .deletePrompt: pendingDeleteIDs = []; transitionToDone()  // Keep
        case .done: break
        }
    }

    @objc private func secondaryTapped() {
        switch phase {
        case .cards: currentCard?.performAction(.markRead)
        case .deletePrompt: pendingDeleteIDs = deleteReadView?.selectedItemIDs ?? []; transitionToDone()
        case .done: commitAndClose()
        }
    }

    private func transitionToDone() {
        phase = .done
        deleteReadView?.removeFromSuperview()
        deleteReadView = nil
        messageView.show(symbol: "checkmark.circle.fill", tint: GlassStyle.readingAccent, text: "All done!")
        messageView.isHidden = false
        updateChrome()
    }

    @objc private func leftTapped() {
        // Cards back / end-screen X — close, applying any pending deletion.
        commitAndClose()
    }

    @objc private func rightTapped() {
        switch phase {
        case .cards:
            guard let item = currentItem, item.isShareable else { return }
            AppReaderShareProvider.shared.presentShareSheet(
                urlString: item.urlString, title: item.title, from: self, sourceView: rightButton)
        case .done:
            store.restore(snapshot)
            dismiss(animated: true)
        case .deletePrompt:
            break
        }
    }

    private func commitAndClose() {
        for id in pendingDeleteIDs {
            if let item = store.item(withID: id) { store.delete(item) }
        }
        dismiss(animated: true)
    }
}
