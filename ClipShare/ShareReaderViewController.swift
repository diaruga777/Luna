//
//  ShareReaderViewController.swift
//  ClipShare
//

import UIKit
import WebKit

/// A self-contained, single-article reader shown inside the share extension
/// when the user picks a share-sheet reading experience. It cannot reach the
/// rest of the app — just this one article, then Done.
///
/// It is deliberately independent of the main app's reader stack (which pulls
/// in CloudKit, the camera, and SwiftSoup — inappropriate for an extension):
/// `reader` shows the page in a web view; `rsvp`/`chunk` extract the page text
/// and present a compact speed reader.
final class ShareReaderViewController: UIViewController, WKNavigationDelegate {

    enum Mode: String {
        case reader, rsvp, chunk
    }

    private let url: URL
    private let mode: Mode
    private let onDone: () -> Void

    private let webView = WKWebView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let accent = UIColor.systemIndigo

    // Speed-reader state (rsvp/chunk).
    private var words: [String] = []
    private var currentIndex = 0
    private var timer: Timer?
    private var isPlaying = false
    private let wordLabel = UILabel()
    private let focusPill = ShareReaderViewController.makeFocusPill()
    private let textView = UITextView()
    private let playButton = UIButton(type: .system)
    /// Fixed pace for the in-sheet speed reader.
    private let wpm: Double = 350
    private let chunkSize = 3

    init(url: URL, mode: Mode, onDone: @escaping () -> Void) {
        self.url = url
        self.mode = mode
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let doneBar = UIView()
        doneBar.backgroundColor = .systemBackground
        let doneButton = UIButton(type: .system)
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        doneButton.tintColor = accent
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        let title = UILabel()
        title.text = url.host
        title.font = .preferredFont(forTextStyle: .footnote)
        title.textColor = .secondaryLabel

        [doneBar, doneButton, title, webView, spinner, textView, focusPill, wordLabel, playButton]
            .forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }

        webView.navigationDelegate = self
        webView.isHidden = mode != .reader
        textView.isHidden = mode == .reader
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 19)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 80, right: 16)
        wordLabel.isHidden = mode != .rsvp
        focusPill.isHidden = mode != .rsvp
        wordLabel.font = .monospacedSystemFont(ofSize: 34, weight: .medium)
        wordLabel.textAlignment = .center
        playButton.isHidden = mode == .reader
        playButton.tintColor = accent
        playButton.setImage(UIImage(systemName: "pause.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34)), for: .normal)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)

        NSLayoutConstraint.activate([
            doneBar.topAnchor.constraint(equalTo: view.topAnchor),
            doneBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            doneBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            doneBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 44),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            doneButton.bottomAnchor.constraint(equalTo: doneBar.bottomAnchor, constant: -8),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),

            webView.topAnchor.constraint(equalTo: doneBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            textView.topAnchor.constraint(equalTo: doneBar.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            focusPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            focusPill.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            focusPill.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48),
            focusPill.heightAnchor.constraint(equalToConstant: 84),
            wordLabel.centerXAnchor.constraint(equalTo: focusPill.centerXAnchor),
            wordLabel.centerYAnchor.constraint(equalTo: focusPill.centerYAnchor),

            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])

        spinner.startAnimating()
        webView.load(URLRequest(url: url))
    }

    @objc private func doneTapped() {
        timer?.invalidate()
        dismiss(animated: true) { [weak self] in self?.onDone() }
    }

    // MARK: - Web load → text extraction for speed modes

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard mode != .reader else {
            spinner.stopAnimating()
            return
        }
        webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
            guard let self else { return }
            self.spinner.stopAnimating()
            let text = (result as? String) ?? ""
            self.words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if self.mode == .chunk { self.textView.text = self.words.joined(separator: " ") }
            self.startPlaying()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }

    // MARK: - Compact speed reader

    private func startPlaying() {
        guard !words.isEmpty else { return }
        isPlaying = true
        playButton.setImage(UIImage(systemName: "pause.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34)), for: .normal)
        showCurrent()
        scheduleNext()
    }

    @objc private func togglePlay() {
        isPlaying.toggle()
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34)), for: .normal)
        if isPlaying { scheduleNext() } else { timer?.invalidate() }
    }

    private func step() -> Int { mode == .chunk ? chunkSize : 1 }

    private func showCurrent() {
        guard currentIndex < words.count else { return }
        if mode == .rsvp {
            wordLabel.text = words[currentIndex]
        } else {
            let end = min(currentIndex + chunkSize, words.count)
            highlightChunk(from: currentIndex, to: end)
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let perWord = 60.0 / wpm
        let interval = perWord * Double(step())
        timer = Timer.scheduledTimer(withTimeInterval: max(0.12, interval), repeats: false) {
            [weak self] _ in self?.advance()
        }
    }

    private func advance() {
        guard isPlaying else { return }
        currentIndex += step()
        guard currentIndex < words.count else {
            isPlaying = false
            playButton.setImage(UIImage(systemName: "checkmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)), for: .normal)
            if mode == .rsvp { wordLabel.text = "Done" }
            return
        }
        showCurrent()
        scheduleNext()
    }

    /// Highlights a word range in the chunk text view and scrolls it to center.
    private func highlightChunk(from startWord: Int, to endWord: Int) {
        let full = textView.text as NSString
        var location = 0
        for _ in 0..<startWord {
            let next = full.range(of: " ", range: NSRange(location: location, length: full.length - location))
            guard next.location != NSNotFound else { break }
            location = next.location + 1
        }
        var end = location
        for _ in startWord..<endWord {
            let next = full.range(of: " ", range: NSRange(location: end, length: full.length - end))
            end = next.location == NSNotFound ? full.length : next.location + 1
        }
        let range = NSRange(location: location, length: max(0, min(end, full.length) - location))
        let attributed = NSMutableAttributedString(
            string: textView.text, attributes: [.font: textView.font ?? .systemFont(ofSize: 19),
                                                 .foregroundColor: UIColor.label])
        attributed.addAttribute(.backgroundColor, value: accent.withAlphaComponent(0.28), range: range)
        textView.attributedText = attributed
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Glass

    private static func makeFocusPill() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = UIColor.systemIndigo.withAlphaComponent(0.16)
            let pill = UIVisualEffectView(effect: glass)
            pill.cornerConfiguration = .capsule()
            return pill
        }
        let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        pill.layer.cornerRadius = 42
        pill.clipsToBounds = true
        return pill
    }
}
