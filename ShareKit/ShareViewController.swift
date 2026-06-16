//
//  ShareViewController.swift
//  ClipShare
//

import Intents
import UIKit
import UniformTypeIdentifiers

/// Zero-UI share extension: receives a web URL or a document (PDF/text/
/// Markdown/RTF) from the share sheet, appends it to the shared reading list,
/// and completes immediately. The main app downloads/parses on next launch.
///
/// When launched by tapping a Click friend in the share sheet's people row, the
/// shared URL is queued as an outgoing friend-share for the main app to send
/// (the extension has no crypto/CloudKit access).
final class ShareViewController: UIViewController {

    /// Document file types accepted from the share sheet. `.text` (public.text)
    /// covers .txt, .md/.markdown, and most source/plain formats.
    private static let documentTypes: [UTType] = [.pdf, .rtf, .plainText, .text]

    /// True when hosted by the "Read in Click" action extension
    /// (`com.apple.ui-services`) rather than the zero-UI share extension
    /// (`com.apple.share-services`). The action extension always opens the
    /// reader; the share extension only does when the user enabled it.
    private var isActionExtension: Bool {
        let nsExtension = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any]
        return (nsExtension?["NSExtensionPointIdentifier"] as? String) == "com.apple.ui-services"
    }

    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        // Build the loading UI FIRST, before any processing, so the action
        // extension always shows *something* and stays on screen — and so any
        // failure can surface as visible error text instead of a silent death.
        if isActionExtension {
            setUpStatusUI()
        } else {
            view.backgroundColor = .clear
        }

        // Defensive: never let a thrown error or unexpected state kill the
        // extension outright — the worst case is the error UI.
        let host = isActionExtension ? "action" : "share"
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            SharedDiagnosticLog.record(
                "\(host) extension: no attachments (\(items.count) item(s))", category: "share")
            failOrComplete("Nothing to read was shared.")
            return
        }
        let types = providers.map { $0.registeredTypeIdentifiers.joined(separator: "|") }
            .joined(separator: ", ")
        SharedDiagnosticLog.record(
            "\(host) extension: \(providers.count) attachment(s) types=[\(types)]", category: "share")

        // Tapped a Click friend suggestion in the share sheet's PEOPLE ROW: the
        // conversation identifier is the friend's UUID. This only happens for
        // the share extension — guard the `intent` access behind that, since
        // touching `extensionContext.intent` in a `com.apple.ui-services` action
        // extension is unnecessary and a likely crash point.
        if !isActionExtension,
           let intent = extensionContext?.intent as? INSendMessageIntent,
           let conversationID = intent.conversationIdentifier,
           let friendUUID = UUID(uuidString: conversationID),
           let urlProvider = providers.first(where: {
               $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
           }) {
            handleFriendShare(urlProvider, friendUUID: friendUUID)
            return
        }

        // Safari (action extension) delivers the page URL via the JavaScript
        // preprocessing result — a property-list attachment — NOT a public.url.
        if let plistProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }) {
            handleJavaScriptResult(plistProvider)
            return
        }

        // A genuine web link conforms to public.url but NOT to a document type.
        // A shared file (e.g. a PDF) ALSO conforms to public.url (as a file-url),
        // so it must be matched as a document first — otherwise the URL branch
        // grabs it, sees a non-http file:// URL, and silently drops it.
        func isDocument(_ provider: NSItemProvider) -> Bool {
            Self.documentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }

        if let webProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) && !isDocument($0)
        }) {
            handleURL(webProvider)
            return
        }
        for provider in providers {
            if let type = Self.documentTypes.first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) {
                handleDocument(provider, type: type)
                return
            }
        }
        // Fallback: a plain URL we didn't classify as a web link above.
        if let urlProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            handleURL(urlProvider)
            return
        }
        failOrComplete("This type of content can't be read in Click.")
    }

    // MARK: - Status / error UI (action extension)

    private func setUpStatusUI() {
        view.backgroundColor = .systemBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Opening in Click…"
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Close", for: .normal)
        closeButton.isHidden = true
        closeButton.addAction(UIAction { [weak self] _ in self?.complete() }, for: .touchUpInside)
        view.addSubview(spinner)
        view.addSubview(statusLabel)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            closeButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    /// Action extension: surface a failure as visible error text (never a silent
    /// death). Share extension: stay zero-UI and just complete.
    private func failOrComplete(_ message: String) {
        SharedDiagnosticLog.record("share extension finished: \(message)", category: "share")
        guard isActionExtension else { complete(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spinner.stopAnimating()
            self.statusLabel.textColor = .label
            self.statusLabel.text = message
            self.closeButton.isHidden = false
        }
    }

    /// Handles the Safari JavaScript-preprocessing result: a property-list whose
    /// `NSExtensionJavaScriptPreprocessingResultsKey` holds `{URL, title}`.
    private func handleJavaScriptResult(_ provider: NSItemProvider) {
        SharedDiagnosticLog.record("action: loading JS result", category: "share")
        // Strong self: the work + reader presentation need the VC alive, and
        // there's no retain cycle (nothing holds the closure once it runs).
        provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, error in
            let dict = item as? NSDictionary
            let results = dict?[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary
            let urlString = results?["URL"] as? String
            SharedDiagnosticLog.record(
                "action: JS callback url=\(urlString ?? "nil") err=\(error.map { String(describing: $0) } ?? "nil")",
                category: "share")
            DispatchQueue.main.async {
                if let urlString, urlString.hasPrefix("http"), let url = URL(string: urlString) {
                    SharedReadingListAppender.append(urlString: urlString)
                    SharedDiagnosticLog.record("saved url (js) \(urlString)", category: "share")
                    if let mode = self.readerMode() {
                        self.presentReader(url: url, mode: mode)
                    } else {
                        self.confirmSavedThenComplete()
                    }
                } else {
                    self.failOrComplete("Couldn't read the shared page's address.")
                }
            }
        }
    }

    private func handleURL(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            guard let self else { return }
            if let url = value as? URL, url.absoluteString.hasPrefix("http") {
                SharedReadingListAppender.append(urlString: url.absoluteString)
                SharedDiagnosticLog.record("saved url \(url.absoluteString)", category: "share")
                // Open the article in an in-sheet reader: always for the
                // "Read in Click" action extension, and for the share
                // extension only when the user picked a reader experience.
                if let mode = self.readerMode() {
                    DispatchQueue.main.async { self.presentReader(url: url, mode: mode) }
                } else {
                    self.confirmSavedThenComplete()
                }
            } else if let url = value as? URL, url.isFileURL {
                SharedReadingListAppender.appendDocument(sourceURL: url)
                SharedDiagnosticLog.record("saved file \(url.lastPathComponent)", category: "share")
                self.confirmSavedThenComplete()
            } else {
                SharedDiagnosticLog.record("url attachment had no URL value", category: "share")
                self.failOrComplete("Couldn't read the shared link.")
            }
        }
    }

    /// The reader mode to present, or nil to save silently. Fixed behavior (no
    /// in-app setting): the share extension always saves and dismisses; the
    /// "Read in Click" action extension always opens the reader, in whichever
    /// mode it was last used in (state local to the extension).
    private func readerMode() -> ShareReaderViewController.Mode? {
        isActionExtension ? ActionReaderMode.last : nil
    }

    private func presentReader(url: URL, mode: ShareReaderViewController.Mode) {
        let reader = ShareReaderViewController(url: url, mode: mode) { [weak self] in
            self?.complete()
        }
        let nav = UINavigationController(rootViewController: reader)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func handleDocument(_ provider: NSItemProvider, type: UTType) {
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
            guard let self else { return }
            // The system deletes `url` when this callback returns, so the
            // appender copies it synchronously here.
            if let url {
                SharedReadingListAppender.appendDocument(sourceURL: url)
                SharedDiagnosticLog.record("saved document \(url.lastPathComponent)", category: "share")
                self.confirmSavedThenComplete()
            } else {
                self.failOrComplete("Couldn't read the shared file.")
            }
        }
    }

    private func handleFriendShare(_ provider: NSItemProvider, friendUUID: UUID) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            if let url = value as? URL, url.absoluteString.hasPrefix("http") {
                PendingFriendShareWriter.enqueue(
                    friendUUID: friendUUID, urlString: url.absoluteString)
            }
            self?.complete()
        }
    }

    private func complete() {
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Shows a brief liquid-glass "Saved" checkmark, then completes. Call only
    /// after an actual save (no reader is being presented).
    private func confirmSavedThenComplete() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.showSavedBadge()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { self.complete() }
        }
    }

    private func showSavedBadge() {
        let badge = UIVisualEffectView(effect: GlassStyle.barEffect())
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 24
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true

        let check = UIImageView(image: UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 42, weight: .semibold)))
        check.tintColor = GlassStyle.readingAccent
        check.contentMode = .center
        let label = UILabel()
        label.text = "Saved"
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        let stack = UIStackView(arrangedSubviews: [check, label])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        badge.contentView.addSubview(stack)
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 136),
            badge.heightAnchor.constraint(equalToConstant: 122),
            stack.centerXAnchor.constraint(equalTo: badge.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: badge.contentView.centerYAnchor),
        ])

        badge.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        badge.alpha = 0
        UIView.animate(
            withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.65, initialSpringVelocity: 0.4
        ) {
            badge.transform = .identity
            badge.alpha = 1
        }
    }
}

/// Writes outgoing friend-shares to the App Group queue the main app drains.
/// (The JSON shape must match the app's `PendingFriendShare`.)
private enum PendingFriendShareWriter {
    private struct Share: Codable {
        let friendUUID: UUID
        let urlString: String
    }

    static func enqueue(friendUUID: UUID, urlString: String) {
        guard let fileURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedReadingListAppender.appGroupID)?
            .appendingPathComponent("pendingFriendShares.json")
        else { return }
        var queue: [Share] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Share].self, from: data) {
            queue = decoded
        }
        queue.append(Share(friendUUID: friendUUID, urlString: urlString))
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
