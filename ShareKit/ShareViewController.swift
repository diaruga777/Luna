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
/// When launched by tapping a Queue friend in the share sheet's people row, the
/// shared URL is queued as an outgoing friend-share for the main app to send
/// (the extension has no crypto/CloudKit access).
final class ShareViewController: UIViewController {

    /// Document file types accepted from the share sheet. `.text` (public.text)
    /// covers .txt, .md/.markdown, and most source/plain formats.
    private static let documentTypes: [UTType] = [.pdf, .rtf, .plainText, .text]

    /// True when hosted by the "Read in Queue" action extension
    /// (`com.apple.ui-services`) rather than the zero-UI share extension
    /// (`com.apple.share-services`). The action extension always opens the
    /// reader; the share extension only does when the user enabled it.
    var isActionExtension: Bool {
        let nsExtension = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any]
        return (nsExtension?["NSExtensionPointIdentifier"] as? String) == "com.apple.ui-services"
    }

    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    /// True once the request has been completed, so completion happens at most
    /// once (a double `completeRequest` is undefined behavior). Main-thread only.
    private var hasCompleted = false

    /// Backstop that completes/surfaces an error if an attachment's async
    /// `loadItem` callback never fires — `loadItem` has no timeout of its own, so
    /// a stalled provider would otherwise hang the extension on screen forever.
    private var loadWatchdog: DispatchWorkItem?
    private static let loadTimeout: TimeInterval = 15

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

        // Every path below loads an attachment asynchronously; guard against a
        // provider whose callback never fires.
        armLoadWatchdog()

        // Tapped a Queue friend suggestion in the share sheet's PEOPLE ROW: the
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
        // Some apps (e.g. Apple Podcasts) share the link as TEXT, not a URL —
        // pull the first link out of it.
        if let textProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.text.identifier)
        }) {
            handleText(textProvider)
            return
        }
        failOrComplete("This type of content can't be read in Queue.")
    }

    // MARK: - Status / error UI (action extension)

    private func setUpStatusUI() {
        view.backgroundColor = .systemBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Opening in Queue…"
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
    func failOrComplete(_ message: String) {
        SharedDiagnosticLog.record("share extension finished: \(message)", category: "share")
        cancelLoadWatchdog()
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
        provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            self.cancelLoadWatchdog()
            let dict = item as? NSDictionary
            let results = dict?[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary
            let rawURLString = results?["URL"] as? String
            // Offline-unwrap (Facebook deep link / classic Google News) to a real http
            // URL before the gate; the pipeline finishes any async unwrap downstream.
            let urlString = rawURLString.map(URLUnwrapper.unwrapOffline)
            SharedDiagnosticLog.record(
                "action: JS callback url=\(urlString ?? "nil") err=\(error.map { String(describing: $0) } ?? "nil")",
                category: "share")
            DispatchQueue.main.async {
                if let urlString, urlString.hasPrefix("http"), let url = URL(string: urlString) {
                    SharedReadingListAppender.append(urlString: urlString)
                    SharedDiagnosticLog.record("saved url (js) \(urlString)", category: "share")
                    self.presentSavedOrReader(url: url)
                } else {
                    self.failOrComplete("Couldn't read the shared page's address.")
                }
            }
        }
    }

    private func handleURL(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            guard let self else { return }
            self.cancelLoadWatchdog()
            // Offline-unwrap a Facebook deep link (`fbrpc://…&target_url=…`) /
            // classic Google News id to its real http URL BEFORE the http gate (a
            // file URL is left untouched). The pipeline finishes any async unwrap.
            let raw = value as? URL
            let normalized = raw.flatMap { $0.isFileURL ? $0 : URLUnwrapper.unwrapOffline($0).url }
            if let url = normalized, url.absoluteString.hasPrefix("http") {
                SharedReadingListAppender.append(urlString: url.absoluteString)
                SharedDiagnosticLog.record("saved url \(url.absoluteString)", category: "share")
                self.presentSavedOrReader(url: url)
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

    /// Runs the ONE shared ingest+present flow for the just-appended `originalURL`
    /// through the host-agnostic `ShareSurfaceDriver` (which unwraps + classifies +
    /// processes under a hard timeout, then persists + presents the `Outcome` via this
    /// VC as its `ExtensionHost`). Safe to call from any thread.
    private func presentSavedOrReader(url originalURL: URL) {
        Task { [weak self] in
            guard let self else { return }
            await ShareSurfaceDriver(host: self).ingestAndPresent(originalURL: originalURL)
        }
    }

    /// Handles a shared text item by extracting the first web link from it (how
    /// Apple Podcasts and some apps share). Saves nothing if there's no link.
    private func handleText(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.text.identifier) { [weak self] value, _ in
            guard let self else { return }
            self.cancelLoadWatchdog()
            let text = (value as? String) ?? (value as? NSAttributedString)?.string
            // A Facebook deep link (`fbrpc://…&target_url=…`) shared as text isn't a
            // link `ShareTextURL.extract` can detect, so unwrap it to its real http
            // article first; otherwise fall back to the normal link extraction.
            guard let text, let url = Self.facebookTargetIfPresent(in: text)
                ?? ShareTextURL.extract(from: text) else {
                self.failOrComplete("No link found to save.")
                return
            }
            SharedReadingListAppender.append(urlString: url.absoluteString)
            SharedDiagnosticLog.record("saved url (text) \(url.absoluteString)", category: "share")
            self.presentSavedOrReader(url: url)
        }
    }

    /// The http article inside a Facebook deep link when the shared text IS such a
    /// link (`fbrpc://…&target_url=…`), else nil. `NSDataDetector` can't see the
    /// non-http `fbrpc` scheme, so the normal link extraction misses it.
    private static func facebookTargetIfPresent(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return NewsAggregatorUnwrapper.facebookRedirectTarget(url)
    }

    private func handleDocument(_ provider: NSItemProvider, type: UTType) {
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
            guard let self else { return }
            self.cancelLoadWatchdog()
            // The system deletes `url` when this callback returns, so the
            // appender copies it synchronously here.
            guard let url else {
                self.failOrComplete("Couldn't read the shared file.")
                return
            }
            // A text file that's essentially just a link → import the link, not
            // the file (drop the surrounding text).
            if type.conforms(to: .text),
               let contents = try? String(contentsOf: url, encoding: .utf8),
               let extracted = ShareTextURL.extract(from: contents) {
                SharedReadingListAppender.append(urlString: extracted.absoluteString)
                SharedDiagnosticLog.record(
                    "saved url (text file) \(extracted.absoluteString)", category: "share")
                self.presentSavedOrReader(url: extracted)
                return
            }
            SharedReadingListAppender.appendDocument(sourceURL: url)
            SharedDiagnosticLog.record("saved document \(url.lastPathComponent)", category: "share")
            self.confirmSavedThenComplete()
        }
    }

    private func handleFriendShare(_ provider: NSItemProvider, friendUUID: UUID) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            self?.cancelLoadWatchdog()
            let normalized = (value as? URL).map { URLUnwrapper.unwrapOffline($0).url }
            if let url = normalized, url.absoluteString.hasPrefix("http") {
                PendingFriendShareWriter.enqueue(
                    friendUUID: friendUUID, urlString: url.absoluteString)
            }
            self?.complete()
        }
    }

    fileprivate func complete() {
        DispatchQueue.main.async { [weak self] in self?.finishRequest() }
    }

    /// The single completion chokepoint: idempotent (so the watchdog firing
    /// alongside a slow callback can't double-complete) and always cancels the
    /// watchdog. Main-thread only.
    private func finishRequest() {
        guard !hasCompleted else { return }
        hasCompleted = true
        cancelLoadWatchdog()
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Shows a brief liquid-glass "Saved" checkmark, then completes. Call only
    /// after an actual save (no reader is being presented).
    func confirmSavedThenComplete() {
        cancelLoadWatchdog()
        DispatchQueue.main.async { [weak self] in
            self?.showSavedBadge()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { self?.finishRequest() }
        }
    }

    /// When auto-download is on for the shared link's platform, the extension STAYS
    /// alive showing a "Saving media…" spinner until the download finishes, then the
    /// "Saved" checkmark, then dismisses — so the download completes before the
    /// process is killed. Otherwise it just saves and dismisses normally.
    func autoDownloadThenComplete(urlString: String) {
        cancelLoadWatchdog()
        guard MediaAutoDownloader.isEnabled(forURLString: urlString) else {
            confirmSavedThenComplete()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let downloading = self.showDownloadingBadge()
            Task {
                _ = await MediaAutoDownloader.runIfEnabledAwaiting(forURLString: urlString)
                await MainActor.run {
                    downloading.removeFromSuperview()
                    self.showSavedBadge()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { self.finishRequest() }
                }
            }
        }
    }

    /// Presents the archive web reader full-screen so the user can solve the
    /// archive.today CAPTCHA. Solving it extracts the article and flips the item to
    /// `.ready`, after which we show the checkmark and dismiss; exiting first leaves
    /// the item `.needsCaptcha`, unlockable later from the app.
    /// A liquid-glass badge with a spinner + label (returned so it can be swapped
    /// for the saved checkmark once the in-flight work finishes).
    @discardableResult
    private func showDownloadingBadge(text: String = "Saving media…") -> UIVisualEffectView {
        let badge = UIVisualEffectView(effect: GlassStyle.barEffect())
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 24
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = GlassStyle.readingAccent
        spinner.startAnimating()
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        badge.contentView.addSubview(stack)
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 160),
            badge.heightAnchor.constraint(equalToConstant: 122),
            stack.centerXAnchor.constraint(equalTo: badge.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: badge.contentView.centerYAnchor),
        ])
        return badge
    }

    private func armLoadWatchdog() {
        let work = DispatchWorkItem { [weak self] in
            SharedDiagnosticLog.record("share extension: attachment load timed out", category: "share")
            self?.failOrComplete("Couldn't read the shared content in time.")
        }
        loadWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: work)
    }

    private func cancelLoadWatchdog() {
        loadWatchdog?.cancel()
        loadWatchdog = nil
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

/// `ShareViewController` is the real `ExtensionHost`: a thin adapter over the live
/// `NSExtensionContext` + UIKit chrome. ALL ingest+present decisions live in the
/// host-agnostic `ShareSurfaceDriver` (testable with a fake host); this conformance
/// only surfaces the per-surface data (`isActionExtension`/`readerMode`) and the
/// real side effects (present a modal, complete, the confirmation/error chrome).
extension ShareViewController: ExtensionHost {

    /// The reader mode to present, or nil to save silently. Fixed behavior (no in-app
    /// setting): the share extension always saves and dismisses; the "Read in Queue"
    /// action extension always opens the reader, in whichever mode it was last used in
    /// (state local to the extension).
    var readerMode: ShareReaderViewController.Mode? {
        isActionExtension ? ActionReaderMode.last : nil
    }

    /// Presents `viewController` full-screen, wrapped in a nav controller.
    func presentModally(_ viewController: UIViewController) {
        let nav = UINavigationController(rootViewController: viewController)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
}
