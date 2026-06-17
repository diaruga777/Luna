//
//  InlineReaderViewController.swift
//  Clip
//

import UIKit
import WebKit

/// The inline reader: a rounded, inset glass panel that overlays the article
/// when a link is tapped, leaving the outer reader peeking at top and bottom.
/// The panel embeds the linked page in the chosen reader mode (scroll / highlight
/// / RSVP), with a close/back control (top-left), a mode selector (top), and a
/// save button (top-right). Tapping a link inside pushes a new page onto a stack
/// (close becomes a back chevron); dragging the peeking edges dismisses it.
final class InlineReaderViewController: UIViewController {

    private struct Page {
        let url: URL
        var content: ArticleContent?
    }

    private var pages: [Page]
    private var mode: ReadingListItem.ReaderMode = .scroll
    private let shareProvider: ReaderShareProviding?

    private let dimView = UIView()
    private let card = UIView()
    private let topBar = UIView()
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let modeControl = UISegmentedControl()
    private let bodyContainer = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var currentChild: UIViewController?
    private var webView: WKWebView?
    private var loadTask: Task<Void, Never>?
    private var cardCenterY: CGFloat = 0

    /// 1.5 lines of the outer reader peek above and below the panel.
    private let peek: CGFloat = 44

    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .highlight, .rsvp]
    private static let modeSymbols = ["text.alignleft", "highlighter", "bolt.fill"]

    init(url: URL, shareProvider: ReaderShareProviding?) {
        self.pages = [Page(url: url, content: nil)]
        self.shareProvider = shareProvider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { loadTask?.cancel() }

    private var currentURL: URL { pages.last?.url ?? pages[0].url }

    // MARK: - Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimView)
        let dimTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        dimView.addGestureRecognizer(dimTap)

        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.separator.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: peek),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -peek),
        ])

        setUpTopBar()

        bodyContainer.clipsToBounds = true
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(bodyContainer)
        NSLayoutConstraint.activate([
            bodyContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: bodyContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor),
        ])

        // Drag the peeking edges (or the top bar) down to dismiss.
        for target in [dimView, topBar] {
            target.addGestureRecognizer(
                UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        }

        loadCurrentPage()
    }

    private func setUpTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: card.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),
        ])

        closeButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark", padding: 8)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        saveButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "arrow.down", padding: 8)
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        for (index, symbol) in Self.modeSymbols.enumerated() {
            modeControl.insertSegment(with: UIImage(systemName: symbol), at: index, animated: false)
        }
        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        for control in [closeButton, saveButton, modeControl] {
            control.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(control)
        }
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            saveButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            modeControl.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])
    }

    // MARK: - Pages

    private func loadCurrentPage() {
        updateCloseButton()
        if pages.last?.content != nil {
            showBody()
            return
        }
        // Swap out any current body and show the spinner while fetching.
        teardownBody()
        spinner.startAnimating()
        let targetURL = currentURL
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let content: ArticleContent? = await Task.detached(priority: .userInitiated) {
                guard let html = try? await ArticleFetcher().fetchHTML(from: targetURL) else { return nil }
                return try? ArticleExtractor().extract(html: html, baseURL: targetURL)
            }.value
            await MainActor.run {
                guard let self, !Task.isCancelled, self.currentURL == targetURL else { return }
                if let content, !content.blocks.isEmpty {
                    self.pages[self.pages.count - 1].content = content
                    self.showBody()
                } else {
                    self.showWebFallback()
                }
            }
        }
    }

    private func teardownBody() {
        if let currentChild {
            currentChild.willMove(toParent: nil)
            currentChild.view.removeFromSuperview()
            currentChild.removeFromParent()
            self.currentChild = nil
        }
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private func showBody() {
        guard let content = pages.last?.content else { return }
        spinner.stopAnimating()
        teardownBody()
        modeControl.isHidden = false

        var item = ReadingListItem(urlString: currentURL.absoluteString)
        item.title = content.title

        let child: UIViewController
        switch mode {
        case .scroll, .highlight:
            let scroll = ScrollReaderViewController(
                item: item, content: content, autoHighlight: mode == .highlight,
                shareProvider: nil, gazeTrackerFactory: nil)
            scroll.onLinkTapped = { [weak self] url in self?.pushPage(url) }
            child = scroll
        case .rsvp:
            child = RSVPViewController(item: item, content: content, shareProvider: nil)
        }
        embed(child)
    }

    private func showWebFallback() {
        spinner.stopAnimating()
        teardownBody()
        modeControl.isHidden = true // no reader modes for a raw web page

        let web = WKWebView(frame: bodyContainer.bounds,
                            configuration: WebJunkBlocker.makeConfiguration())
        web.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            web.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
        WebJunkBlocker.applyRuleList(to: web.configuration.userContentController)
        web.load(URLRequest(url: currentURL))
        webView = web
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
        child.didMove(toParent: self)
        currentChild = child
    }

    private func pushPage(_ url: URL) {
        pages.append(Page(url: url, content: nil))
        loadCurrentPage()
    }

    private func popPage() {
        guard pages.count > 1 else { return }
        pages.removeLast()
        loadCurrentPage()
    }

    private func updateCloseButton() {
        let symbol = pages.count > 1 ? "chevron.left" : "xmark"
        closeButton.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 8)
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        mode = Self.orderedModes[
            max(0, min(modeControl.selectedSegmentIndex, Self.orderedModes.count - 1))]
        showBody()
    }

    @objc private func saveTapped() {
        shareProvider?.saveLink(urlString: currentURL.absoluteString)
        // Brief confirmation: flip the plus to a checkmark.
        saveButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "checkmark", padding: 8)
        saveButton.tintColor = GlassStyle.readingAccent
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc private func closeTapped() {
        if pages.count > 1 {
            popPage()
        } else {
            dismissCard()
        }
    }

    private func dismissCard() {
        loadTask?.cancel()
        UIView.animate(withDuration: 0.25, animations: {
            self.card.transform = CGAffineTransform(translationX: 0, y: self.view.bounds.height)
            self.dimView.alpha = 0
        }, completion: { _ in
            self.dismiss(animated: false)
        })
    }

    // MARK: - Drag to dismiss

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view).y
        switch gesture.state {
        case .changed:
            let offset = max(0, translation) // only downward compresses/dismisses
            card.transform = CGAffineTransform(translationX: 0, y: offset)
            dimView.alpha = max(0, 1 - offset / (view.bounds.height * 0.5))
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if translation > 140 || velocity > 800 {
                dismissCard()
            } else {
                UIView.animate(withDuration: 0.25) {
                    self.card.transform = .identity
                    self.dimView.alpha = 1
                }
            }
        default:
            break
        }
    }
}
