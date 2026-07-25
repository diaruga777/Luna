//
//  ShareViewController.swift
//  LunaShare
//

import LunaDesignSystem
import LunaStorage
import LunaIngest
import LunaModels
import LunaURLClassification
import Intents
import UIKit
import UniformTypeIdentifiers

/// Zero-UI share extension: receives a web URL or a document (PDF/text/
/// Markdown/RTF) from the share sheet, appends it to the shared reading list,
/// and completes immediately. The main app downloads/parses on next launch.
///
/// When launched by tapping a Luna friend in the share sheet's people row, the
/// shared URL is queued as an outgoing friend-share for the main app to send
/// (the extension has no crypto/CloudKit access).
open class ShareViewController: UIViewController {

    /// Document file types accepted from the share sheet. `.text` (public.text)
    /// covers .txt, .md/.markdown, and most source/plain formats.
    private static let documentTypes: [UTType] = [.pdf, .rtf, .plainText, .text]

    /// True when hosted by the "Read in Luna" action extension
    /// (`com.apple.ui-services`) rather than the zero-UI share extension
    /// (`com.apple.share-services`). The action extension always opens the
    /// reader; the share extension only does when the user enabled it.
    public var isActionExtension: Bool {
        let nsExtension = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any]
        return (nsExtension?["NSExtensionPointIdentifier"] as? String) == "com.apple.ui-services"
    }

    private let spinner = DotMatrixSpinnerView(side: 36)
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    /// The action extension owns one navigation context for its entire lifetime.
    /// Replacing its root avoids stacking a second modal over the extension sheet.
    private var actionNavigationController: UINavigationController?

    /// True once the request has been completed, so completion happens at most
    /// once (a double `completeRequest` is undefined behavior). Main-thread only.
    private var hasCompleted = false

    /// Backstop that completes/surfaces an error if an attachment's async
    /// `loadItem` callback never fires — `loadItem` has no timeout of its own, so
    /// a stalled provider would otherwise hang the extension on screen forever.
    private var loadWatchdog: DispatchWorkItem?
    private static let loadTimeout: TimeInterval = 15

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Extensions render in the host's window, so they pin their own root:
        // dark UIKit materials, with the user's chosen sky on top.
        AppearanceSettings.apply(to: self)
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

        // Safari (action extension) delivers the page URL via the JavaScript
        // preprocessing result — a property-list attachment — NOT a public.url.
        if let item = items.first(where: { item in
            (item.attachments ?? []).contains {
                $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
            }
        }), let plistProvider = item.attachments?.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }) {
            handleJavaScriptResult(plistProvider, inputItem: item)
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
        // Some apps share the link as TEXT, not a URL —
        // pull the first link out of it.
        if let textProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.text.identifier)
        }) {
            handleText(textProvider)
            return
        }
        failOrComplete("This type of content can't be read in Luna.")
    }

    // MARK: - Status / error UI (action extension)

    private func setUpStatusUI() {
        view.backgroundColor = LunaColors.background
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Opening in Luna…"
        statusLabel.textColor = LunaColors.secondaryText
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
    public func failOrComplete(_ message: String) {
        SharedDiagnosticLog.record("share extension finished: \(message)", category: "share")
        cancelLoadWatchdog()
        guard isActionExtension else { complete(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spinner.stopAnimating()
            self.statusLabel.textColor = LunaColors.primaryText
            self.statusLabel.text = message
            self.closeButton.isHidden = false
        }
    }

    /// Handles the Safari JavaScript-preprocessing result: a property-list whose
    /// `NSExtensionJavaScriptPreprocessingResultsKey` holds `{URL, title, Kind,
    /// ArticleText}`. Safari only sends the compact text snapshot after its cheap DOM
    /// classifier identifies a substantial ordinary article; product/paywall/platform
    /// links continue into their dedicated pipeline paths.
    private func handleJavaScriptResult(_ provider: NSItemProvider, inputItem: NSExtensionItem) {
        SharedDiagnosticLog.record("action: loading JS result", category: "share")
        if let result = Self.javaScriptResult(from: inputItem.userInfo) {
            SharedDiagnosticLog.record("action: read JS result from item userInfo", category: "share")
            consumeJavaScriptResult(result, error: nil)
            return
        }
        loadJavaScriptResult(provider, inputItem: inputItem, attempt: 0)
    }

    /// Safari occasionally exposes its preprocessing provider before its XPC endpoint
    /// is ready (NSItemProvider error -1000 / Cocoa 4101). Retry briefly rather than
    /// treating that transient state as a missing page.
    private func loadJavaScriptResult(
        _ provider: NSItemProvider, inputItem: NSExtensionItem, attempt: Int
    ) {
        // Strong self: the work + reader presentation need the VC alive, and
        // there's no retain cycle (nothing holds the closure once it runs).
        provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let result = Self.javaScriptResult(from: item) {
                self.consumeJavaScriptResult(result, error: error)
                return
            }

            if attempt < 3 {
                SharedDiagnosticLog.record(
                    "action: JS provider empty (attempt \(attempt + 1)); retrying", category: "share")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.loadJavaScriptResult(provider, inputItem: inputItem, attempt: attempt + 1)
                }
                return
            }

            // On recent iOS versions Safari's action-extension provider can advertise
            // `public.property-list` but return nil from `loadItem`. Its bytes are
            // still available through the data-representation API, so decode that
            // representation before treating the page URL as unavailable.
            SharedDiagnosticLog.record(
                "action: JS loadItem returned no decodable property list; retrying as data", category: "share")
            provider.loadDataRepresentation(forTypeIdentifier: UTType.propertyList.identifier) {
                [weak self] data, dataError in
                guard let self else { return }
                let result = data.flatMap(Self.javaScriptResult(fromPropertyListData:))
                    ?? Self.urlOnlyJavaScriptResult(from: inputItem)
                self.consumeJavaScriptResult(result, error: dataError ?? error)
            }
        }
    }

    /// iOS 26 Safari can invalidate the property-list provider despite including the
    /// page URL in the extension item's text metadata. Keep this last-resort path
    /// narrow: only an actual HTTP(S) URL is accepted.
    nonisolated static func urlOnlyJavaScriptResult(from item: NSExtensionItem) -> [String: Any]? {
        let values = [item.attributedContentText?.string, item.attributedTitle?.string]
        for value in values.compactMap({ $0 }) {
            if let url = ShareTextURL.extract(from: value) {
                return ["URL": url.absoluteString, "Kind": "unknown"]
            }
        }
        return nil
    }

    /// Extracts Safari's preprocessing dictionary from either its normal wrapped
    /// property-list shape or the direct payload shape seen from some extension hosts.
    /// Deliberately Foundation-only so it is identical in the app and
    /// action-extension processes.
    nonisolated static func javaScriptResult(from item: Any?) -> [String: Any]? {
        let dictionary: [String: Any]?
        if let payload = item as? [String: Any] {
            dictionary = payload
        } else if let payload = item as? NSDictionary {
            dictionary = payload as? [String: Any]
        } else if let data = item as? Data {
            return javaScriptResult(fromPropertyListData: data)
        } else {
            dictionary = nil
        }
        guard let dictionary else { return nil }
        if let wrapped = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
            return wrapped
        }
        return dictionary["URL"] is String ? dictionary : nil
    }

    nonisolated static func javaScriptResult(fromPropertyListData data: Data) -> [String: Any]? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        else { return nil }
        return javaScriptResult(from: propertyList)
    }

    private func consumeJavaScriptResult(_ result: [String: Any]?, error: Error?) {
        cancelLoadWatchdog()
        let rawURLString = result?["URL"] as? String
        let title = result?["title"] as? String
        let kind = result?["Kind"] as? String
        let articleText = result?["ArticleText"] as? String
        // The snapshot is of the page the user was ON. When that URL unwraps to a
        // different page — a publisher's subscribe interstitial holding the article
        // behind `?dest=` — the snapshot is the subscription pitch, so it must not
        // travel with the unwrapped article URL.
        let capturesOwnPage = rawURLString.map { !URLUnwrapper.unwrapsToDifferentPage($0) } ?? false
        let prefetchedHTML = kind == "article" && capturesOwnPage
            ? Self.articleSnapshotHTML(title: title, text: articleText)
            : nil
        let url = rawURLString.flatMap { URLUnwrapper.ingestURL(from: $0) }
        SharedDiagnosticLog.record(
            "action: JS callback url=\(url?.absoluteString ?? "nil") err=\(error.map { String(describing: $0) } ?? "nil")",
            category: "share")
        DispatchQueue.main.async {
            if let url {
                SharedReadingListAppender.append(urlString: url.absoluteString)
                SharedDiagnosticLog.record("saved url (js) \(url.absoluteString)", category: "share")
                self.presentSavedOrReader(url: url, prefetchedHTML: prefetchedHTML)
            } else {
                self.failOrComplete("Couldn't read the shared page's address.")
            }
        }
    }

    private func handleURL(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            guard let self else { return }
            self.cancelLoadWatchdog()
            let raw = value as? URL
            if let raw, raw.isFileURL {
                self.saveDocumentDirectly(sourceURL: raw)
            } else if let raw, let url = URLUnwrapper.ingestURL(from: raw.absoluteString) {
                SharedReadingListAppender.append(urlString: url.absoluteString)
                SharedDiagnosticLog.record("saved url \(url.absoluteString)", category: "share")
                self.presentSavedOrReader(url: url)
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
    private func presentSavedOrReader(url originalURL: URL, prefetchedHTML: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            await ShareSurfaceDriver(host: self).ingestAndPresent(
                originalURL: originalURL, prefetchedHTML: prefetchedHTML)
        }
    }

    /// Converts Safari's text-only action snapshot into the smallest valid HTML
    /// document our shared extractor consumes. The JavaScript preprocessor classifies
    /// before sending this data, so this never turns a product or paywall into an
    /// article merely to avoid a fetch.
    private static func articleSnapshotHTML(title: String?, text: String?) -> String? {
        guard let text, text.count >= ArticleContent.readableBodyThreshold else { return nil }
        let escapedTitle = escapeHTML(title ?? "Untitled")
        let escapedText = escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
        return "<html><head><title>\(escapedTitle)</title></head>"
            + "<body><article><p>\(escapedText)"
            + "</p></article></body></html>"
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Handles a shared text item by extracting its first web link. Saves nothing
    /// if there is no link.
    private func handleText(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.text.identifier) { [weak self] value, _ in
            guard let self else { return }
            self.cancelLoadWatchdog()
            let text = (value as? String) ?? (value as? NSAttributedString)?.string
            // A Facebook deep link (`fbrpc://…&target_url=…`) shared as text isn't a
            // link `ShareTextURL.extract` can detect, so unwrap it to its real http
            // article first; otherwise fall back to the normal link extraction.
            guard let text, let extracted = Self.facebookTargetIfPresent(in: text)
                ?? ShareTextURL.extract(from: text),
                  let url = URLUnwrapper.ingestURL(from: extracted.absoluteString) else {
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
               let extracted = ShareTextURL.extract(from: contents),
               let normalized = URLUnwrapper.ingestURL(from: extracted.absoluteString) {
                SharedReadingListAppender.append(urlString: normalized.absoluteString)
                SharedDiagnosticLog.record(
                    "saved url (text file) \(normalized.absoluteString)", category: "share")
                self.presentSavedOrReader(url: normalized)
                return
            }
            self.saveDocumentDirectly(sourceURL: url)
        }
    }

    /// The direct document-save path — imported files never route through
    /// `ShareSurfaceDriver` (no classification needed; a file IS a `.document`),
    /// so the per-app content gate runs here instead. Documents belong to Luna
    /// Reader, so only Reader and the central Luna app accept them; a dropped
    /// document is checked BEFORE appending, so it never copies its file into
    /// the App Group at all — nothing to clean up. Synchronous up to the append
    /// (the system deletes the source file when the provider callback returns,
    /// so the copy can't be deferred).
    private func saveDocumentDirectly(sourceURL: URL) {
        switch SurfaceSupport.evaluateForCurrentProcess(owner: .reader) {
        case .supported:
            SharedReadingListAppender.appendDocument(sourceURL: sourceURL)
            SharedDiagnosticLog.record(
                "saved document \(sourceURL.lastPathComponent)", category: "share")
            completeAfterDirectSave()
        case .unsupported(let owner):
            SharedDiagnosticLog.record(
                "dropped foreign-kind document save", category: "share")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let error = UnsupportedSaveViewController(owner: owner, currentApp: .current)
                error.onDone = { [weak self] in self?.completeSilently() }
                self.presentModally(error)
            }
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
    public func confirmSavedThenComplete() {
        cancelLoadWatchdog()
        DispatchQueue.main.async { [weak self] in
            self?.showSavedBadge()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { self?.finishRequest() }
        }
    }

    public func completeSilently() {
        cancelLoadWatchdog()
        complete()
    }

    /// Best-effort deep link into the containing app (the rescue-failure card's
    /// "Finish in Luna" step). Extensions have no `UIApplication.shared`;
    /// `extensionContext.open` is the sanctioned (if not universally honored)
    /// route, and the card always shows manual fallback instructions too.
    public func openURL(_ url: URL) {
        extensionContext?.open(url, completionHandler: nil)
    }

    private func completeAfterDirectSave() {
        if isActionExtension {
            confirmSavedThenComplete()
        } else {
            completeSilently()
        }
    }

    /// When auto-download is on for the shared link's platform, hand the media
    /// download to the system background-transfer service and Live Activity before
    /// dismissing. The extension process is intentionally NOT the owner of the
    /// transfer; it may be killed as soon as this request completes. The handoff
    /// itself comes from the registered media presenter (`ShareKindPresenters`,
    /// kind-neutral here) — no presenter, or auto-download off, means there is
    /// nothing to start, so just confirm the save (matching a non-media app).
    public func autoDownloadThenComplete(urlString: String) {
        cancelLoadWatchdog()
        guard let media = ShareKindPresenters.media, media.shouldAutoDownload(urlString: urlString) else {
            confirmSavedThenComplete()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let downloading = self.showDownloadingBadge(text: "Starting download…")
            Task {
                await media.startAutoDownload(urlString: urlString)
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

        let spinner = DotMatrixSpinnerView(side: 36)
        spinner.color = GlassStyle.readingAccent
        spinner.startAnimating()
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = LunaColors.primaryText
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
        label.textColor = LunaColors.primaryText
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
    /// setting): the share extension always saves and dismisses; the "Read in Luna"
    /// action extension always opens the reader, in whichever mode it was last used in
    /// (state local to the extension).
    public var readerMode: ExtensionReaderMode? {
        isActionExtension ? ActionReaderMode.last : nil
    }

    /// The share extension presents normally. The action extension keeps all of its
    /// screens inside one embedded navigation controller, so archive → reader does
    /// not create a second presentation that can dismiss the extension host.
    public func presentModally(_ viewController: UIViewController) {
        if isActionExtension {
            spinner.stopAnimating()
            statusLabel.isHidden = true
            closeButton.isHidden = true
            if let navigationController = actionNavigationController {
                navigationController.setViewControllers([viewController], animated: false)
                return
            }
            let navigationController = UINavigationController(rootViewController: viewController)
            navigationController.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(navigationController)
            view.addSubview(navigationController.view)
            NSLayoutConstraint.activate([
                navigationController.view.topAnchor.constraint(equalTo: view.topAnchor),
                navigationController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                navigationController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                navigationController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            navigationController.didMove(toParent: self)
            actionNavigationController = navigationController
            return
        }
        let nav = UINavigationController(rootViewController: viewController)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
}
