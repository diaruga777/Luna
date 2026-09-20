//
//  ShareViewController.swift
//  LunaShare
//

import LunaDesignSystem
import LunaHTMLClassification
import LunaStorage
import LunaIngest
import LunaModels
import LunaURLClassification
import Intents
import UIKit
import UniformTypeIdentifiers

/// Zero-UI share extension: receives a web URL or a document (PDF, text,
/// Markdown, or RTF) from the share sheet, appends it to the shared saves
/// list, and completes immediately. The main app downloads and parses it on
/// its next launch.
///
/// When launched by tapping a Luna friend in the share sheet's people row,
/// this queues the shared URL as an outgoing friend-share for the main app
/// to send, since the extension has no crypto or CloudKit access.
open class ShareViewController: UIViewController {

    /// True when hosted by the "Read in Luna" action extension
    /// (`com.apple.ui-services`), rather than the zero-UI share extension
    /// (`com.apple.share-services`). The action extension always opens the
    /// reader; the share extension does only when the user enabled it.
    ///
    /// An in-app host counts as the action extension: it embeds this
    /// surface to show what saving looks like, so it wants the status
    /// chrome and the reader, not the zero-UI terminal.
    public var isActionExtension: Bool {
        if hostedInput != nil { return true }
        let nsExtension = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any]
        return (nsExtension?["NSExtensionPointIdentifier"] as? String) == "com.apple.ui-services"
    }

    /// What an in-app host asked this surface to run, or nil in a real extension.
    private var hostedInput: HostedShareInput?
    /// Replaces `extensionContext.completeRequest` when hosted. Called at most
    /// once, from the same chokepoint (`finishRequest`).
    private var hostedFinish: (() -> Void)?

    /// True when this surface runs inside the app rather than an extension
    /// process. It changes exactly three things — where the input comes
    /// from, what completion means, and that no cross-process setup
    /// evidence gets written — and nothing about the ingest/present
    /// decisions in between.
    public var isHosted: Bool { hostedInput != nil }

    /// Whether a save through this surface counts as the user having
    /// driven the share/action extension: the cross-process evidence the
    /// onboarding save lesson watches for. False in hosted mode and
    /// nowhere else — a rehearsal the app played to itself must not
    /// complete a setup step on the user's behalf.
    public var recordsSetupRunEvidence: Bool { !isHosted }

    /// Runs the real share/action surface inside the app, over `hosted`,
    /// calling `onFinish` where an extension would complete its request.
    ///
    /// This exists so the onboarding save lesson can be the actual thing,
    /// not a picture of it: the same attachment-free entry, the same
    /// `ShareSurfaceDriver`, the same per-kind presenters, the same error
    /// states. This is a convenience initializer on purpose — the
    /// extension targets' principal classes subclass this and instantiate
    /// through `init(nibName:bundle:)`, which must stay the designated
    /// route in.
    public convenience init(
        hosted input: HostedShareInput,
        onFinish: @escaping () -> Void
    ) {
        self.init(nibName: nil, bundle: nil)
        hostedInput = input
        hostedFinish = onFinish
    }

    /// The action extension's wait screen, nil in the zero-UI share
    /// extension. Kept so a terminal message can show on the same screen
    /// the wait happened on, rather than on a second one that swaps the
    /// header out from under it.
    private var loadingScreen: ExtensionLoadingViewController?
    /// The action extension owns one navigation context for its entire
    /// lifetime. Replacing its root avoids stacking a second modal over
    /// the extension sheet.
    private var actionNavigationController: UINavigationController?

    /// True once the request has completed, so completion happens at most
    /// once — a double `completeRequest` is undefined behavior. Main
    /// thread only.
    private var hasCompleted = false

    /// Backstop that completes or surfaces an error if an attachment's
    /// async `loadItem` callback never fires. `loadItem` has no timeout of
    /// its own, so a stalled provider would otherwise hang the extension
    /// on screen forever.
    private var loadWatchdog: DispatchWorkItem?
    private static let loadTimeout: TimeInterval = 15

    /// The one surface this extension process shows. An extension has exactly
    /// one view controller, and the intake witness the composition root
    /// installs — before any controller exists — has to find it later.
    static weak var activeSurface: ShareViewController?

    public override func viewDidLoad() {
        super.viewDidLoad()
        Self.activeSurface = self
        // Extensions render in the host's window, so they pin their own
        // root: dark UIKit materials, with the user's chosen sky on top.
        AppearanceSettings.apply(to: self)
        // Builds the loading UI first, before any processing, so the
        // action extension always shows something and stays on screen, and
        // so any failure can surface as visible error text instead of a
        // silent death.
        if isActionExtension {
            setUpStatusUI()
        } else {
            view.backgroundColor = .clear
        }

        // An in-app host supplies the link directly, so there is no
        // `extensionContext`: no attachments to route, and no watchdog to
        // arm around loading them.
        if let hostedInput {
            switch hostedInput {
            case let .url(url):
                handleHostedURL(url)
            case let .offlineFailure(url):
                presentHostedOfflineFailure(url: url)
            }
            return
        }

        // Defensive: never let a thrown error or unexpected state kill the
        // extension outright. The worst case is the error UI.
        let host = isActionExtension ? "action" : "share"
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            SharedDiagnosticLog.record(
                "\(host) extension: no attachments (\(items.count) item(s))", category: "share")
            failOrComplete(L10n.string("ShareExtension_share_noAttachmentsMessage"))
            return
        }
        // The route is decided from what the providers advertise, by the
        // pure `ShareAttachmentRouter` (unit-tested, since the real share
        // sheet has no test seam). Logged next to the types so a misrouted
        // share is diagnosable from the shared log alone.
        let route = ShareAttachmentRouter.route(
            providerTypes: providers.map { $0.registeredTypeIdentifiers })
        let types = providers.map { $0.registeredTypeIdentifiers.joined(separator: "|") }
            .joined(separator: ", ")
        SharedDiagnosticLog.record(
            "\(host) extension: \(providers.count) attachment(s) types=[\(types)] "
                + "route=\(route.diagnosticLabel)", category: "share")

        // Every path below loads an attachment asynchronously. This guards
        // against a provider whose callback never fires.
        armLoadWatchdog()

        // Safari's action extension delivers the page URL through the
        // JavaScript preprocessing result, a property-list attachment, not
        // a public.url.
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

        switch route {
        case let .webURL(index):
            handleURL(providers[index])
        case let .document(index, type):
            handleDocument(providers[index], type: type)
        case let .lunaFile(index, typeIdentifier):
            handleLunaFile(providers[index], typeIdentifier: typeIdentifier)
        case let .text(index):
            // Some apps share the link as text, not a URL. Pull the first
            // link out of it.
            handleText(providers[index])
        case .unsupported:
            failOrComplete(L10n.string("ShareExtension_share_unsupportedContentMessage"))
        }
    }

    // MARK: - Status / error UI (action extension)

    /// The action extension's wait, as a navigation root rather than views
    /// on this controller, so the header — and the way out of it — is on
    /// screen from the first frame instead of appearing partway through,
    /// once the archive reader becomes the sheet's navigation root.
    private func setUpStatusUI() {
        view.backgroundColor = LunaColors.background
        let loading = ExtensionLoadingViewController(
            initialText: L10n.string("Common_openingInLuna"), exitDelegate: self)
        loadingScreen = loading
        hostInNavigation(loading)
    }

    /// Action extension: surfaces a failure as visible error text, never a
    /// silent death. Share extension: stays zero-UI and just completes.
    ///
    /// This is the `ExtensionHost` requirement, so it takes the message and
    /// nothing else. It has no defaulted parameters, which would stop it
    /// from satisfying that requirement.
    public func failOrComplete(_ message: String) {
        failOrComplete(message, symbolName: nil, detail: nil)
    }

    /// The same terminal, dressed: `symbolName` takes the stopped spinner's
    /// place, and `detail` sits under the message. For a failure that has
    /// a shape worth drawing, not just a sentence.
    public func failOrComplete(
        _ message: String,
        symbolName: String?,
        detail: String?
    ) {
        SharedDiagnosticLog.record("share extension finished: \(message)", category: "share")
        cancelLoadWatchdog()
        guard isActionExtension else { complete(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The error lands on the wait screen itself, whose header
            // already carries the exit, so there is no second close
            // affordance to reveal and the sheet's chrome doesn't change
            // shape at the moment of bad news. A route that failed before
            // the wait screen existed (an in-app host) gets one now.
            if self.loadingScreen == nil {
                self.setUpStatusUI()
            }
            self.loadingScreen?.showTerminal(
                message, symbolName: symbolName, detail: detail)
            // Visible error text is a terminal state: nothing further
            // happens until somebody taps Close, and an in-app host has no
            // finger to do it with.
            if self.isHosted {
                HostedShareSession.current?.delegate?.hostedShareSessionReachedTerminal()
            }
        }
    }

    /// Handles the Safari JavaScript-preprocessing result: a property list
    /// whose `NSExtensionJavaScriptPreprocessingResultsKey` holds `{URL,
    /// title, Kind, ArticleText}`. Safari sends the compact text snapshot
    /// only after its cheap DOM classifier identifies a substantial
    /// ordinary article; product, paywall, and platform links continue
    /// into their own dedicated pipeline paths.
    private func handleJavaScriptResult(_ provider: NSItemProvider, inputItem: NSExtensionItem) {
        SharedDiagnosticLog.record("action: loading JS result", category: "share")
        if let result = Self.javaScriptResult(from: inputItem.userInfo) {
            SharedDiagnosticLog.record("action: read JS result from item userInfo", category: "share")
            consumeJavaScriptResult(result, error: nil)
            return
        }
        loadJavaScriptResult(provider, inputItem: inputItem, attempt: 0)
    }

    /// Safari occasionally exposes its preprocessing provider before its
    /// XPC endpoint is ready (`NSItemProvider` error -1000 / Cocoa 4101).
    /// This retries briefly instead of treating that transient state as a
    /// missing page.
    private func loadJavaScriptResult(
        _ provider: NSItemProvider, inputItem: NSExtensionItem, attempt: Int
    ) {
        // Strong self: the work and reader presentation need the view
        // controller alive, and there is no retain cycle, since nothing
        // holds the closure once it runs.
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

            // On recent iOS versions, Safari's action-extension provider
            // can advertise `public.property-list` but return nil from
            // `loadItem`. Its bytes are still available through the
            // data-representation API, so this decodes that representation
            // before treating the page URL as unavailable.
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

    /// iOS 26 Safari can invalidate the property-list provider despite
    /// including the page URL in the extension item's text metadata. This
    /// last-resort path stays narrow: it accepts only an actual HTTP(S)
    /// URL.
    nonisolated static func urlOnlyJavaScriptResult(from item: NSExtensionItem) -> [String: Any]? {
        let values = [item.attributedContentText?.string, item.attributedTitle?.string]
        for value in values.compactMap({ $0 }) {
            if let url = ShareTextURL.extract(from: value) {
                return ["URL": url.absoluteString, "Kind": "unknown"]
            }
        }
        return nil
    }

    /// Extracts Safari's preprocessing dictionary from either its normal
    /// wrapped property-list shape or the direct payload shape seen from
    /// some extension hosts. Foundation-only on purpose, so it behaves
    /// identically in the app and action-extension processes.
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
        // The snapshot is of the page the user was on. When that URL
        // unwraps to a different page — a publisher's subscribe
        // interstitial holding the article behind `?dest=` — the snapshot
        // is the subscription pitch, so it must not travel with the
        // unwrapped article URL.
        let capturesOwnPage = rawURLString.map { !URLUnwrapper.unwrapsToDifferentPage($0) } ?? false
        let page: CapturedPage = kind == "article" && capturesOwnPage
            ? (Self.articleSnapshotHTML(title: title, text: articleText).map {
                CapturedPage.fetched($0)
              } ?? .none)
            : .none
        let url = rawURLString.flatMap { URLUnwrapper.ingestURL(from: $0) }
        SharedDiagnosticLog.record(
            "action: JS callback url=\(url?.absoluteString ?? "nil") err=\(error.map { String(describing: $0) } ?? "nil")",
            category: "share")
        DispatchQueue.main.async {
            if let url {
                SavesStore.shared.addIfAbsent(
                    urlString: url.absoluteString, source: .shareSheet)
                SharedDiagnosticLog.record("saved url (js) \(url.absoluteString)", category: "share")
                self.presentSavedOrReader(url: url, page: page)
            } else {
                self.failOrComplete(L10n.string("ShareExtension_share_missingPageAddressMessage"))
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
                if self.presentShareSetupPracticeIfNeeded(url) { return }
                SavesStore.shared.addIfAbsent(
                    urlString: url.absoluteString, source: .shareSheet)
                SharedDiagnosticLog.record("saved url \(url.absoluteString)", category: "share")
                self.presentSavedOrReader(url: url)
            } else {
                SharedDiagnosticLog.record("url attachment had no URL value", category: "share")
                self.failOrComplete(L10n.string("ShareExtension_share_missingLinkMessage"))
            }
        }
    }

    // MARK: - Hosted (in-app) entry

    /// The hosted twin of `handleURL`'s success leg: appends the URL, then
    /// hands it to the same driver. Deliberately no watchdog, since nothing
    /// is loaded from a provider, and no `ingestURL` unwrap, because the
    /// host resolved the link before opening the sheet.
    private func handleHostedURL(_ url: URL) {
        if presentShareSetupPracticeIfNeeded(url) { return }
        SavesStore.shared.addIfAbsent(
            urlString: url.absoluteString, source: .shareSheet)
        SharedDiagnosticLog.record(
            "hosted surface saved url \(url.absoluteString)", category: "share")
        if let row = SavesStore.shared.item(forURLString: url.absoluteString) {
            HostedShareSession.current?.delegate?.hostedShareSessionDidAppendRow(row.id)
        }
        presentSavedOrReader(url: url)
    }

    /// The genuine offline failure, shown directly: `SaveFailureReason
    /// .offline`'s own headline and suggestion in the surface's own error
    /// state. Nothing is appended and nothing is fetched, since there is
    /// no connection to fetch over, and inventing a save that never
    /// happened is the one thing this lesson must not do.
    private func presentHostedOfflineFailure(url: URL) {
        SharedDiagnosticLog.record(
            "hosted surface offline for \(url.absoluteString)", category: "share")
        // Shows the real failure's own headline, under the symbol for it,
        // but not its suggestion. "It will retry automatically once you're
        // back online" is true of a save the user made and false of this
        // one: a rehearsal's row is deleted the moment the sheet closes,
        // online or off. What the lesson owes the user instead is an
        // admission that they are seeing the shape of a save, not the save
        // itself.
        failOrComplete(
            SaveFailureReason.offline.headline,
            symbolName: "wifi.slash",
            detail: L10n.string("ShareExtension_share_hostedOfflineDetail"))
    }

    /// Runs the one shared ingest-and-present flow for the just-appended
    /// `originalURL` through the host-agnostic `ShareSurfaceDriver`. The
    /// driver unwraps, classifies, and processes under a hard timeout,
    /// then persists and presents the `Outcome` through this view
    /// controller as its `ExtensionHost`. Safe to call from any thread.
    private func presentSavedOrReader(url originalURL: URL, page: CapturedPage = .none) {
        recordShareSurfaceRun()
        Task { [weak self] in
            guard let self else { return }
            await ShareSurfaceDriver(host: self).ingestAndPresent(
                originalURL: originalURL, page: page)
        }
    }

    /// Cross-process evidence that the user really did drive a save through
    /// this app's share/action extension: the one fact the onboarding save
    /// lesson watches for when the real share sheet comes back.
    ///
    /// Recorded for any handled URL, not just the bundled practice link.
    /// The lesson hands the sheet a live Save of the Week when there is
    /// one, and a real save of a real link through the real extension is
    /// more convincing evidence than a rehearsal, not less. The practice
    /// path keeps its own idempotent write, since it deliberately never
    /// reaches here.
    ///
    /// Never records from the in-app hosted mode: a rehearsal the app
    /// played to itself is not the user doing anything.
    private func recordShareSurfaceRun() {
        guard recordsSetupRunEvidence else { return }
        LunaSetupStatusStore.shared.recordShareActionRun(
            isCentral: LunaApp.current == .luna)
    }

    /// Converts Safari's text-only action snapshot into the smallest valid
    /// HTML document the shared extractor consumes. The JavaScript
    /// preprocessor classifies before sending this data, so this never
    /// turns a product or paywall page into an article merely to avoid a
    /// fetch.
    private static func articleSnapshotHTML(title: String?, text: String?) -> String? {
        guard let text, text.count >= ArticleContent.readableBodyThreshold else { return nil }
        let escapedTitle = escapeHTML(title ?? L10n.string("Common_untitled"))
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

    /// Handles a shared text payload: text the host handed over instead of
    /// a URL. A link inside it is the share and wins. `ShareTextURL
    /// .firstLink` allows a caption around it — the YouTube share sheet
    /// sends `<video title>\n<link>`, and importing that caption as a text
    /// document would lose the video. Genuine text with no link, or with a
    /// whole document's worth of prose around one, still imports as a
    /// document.
    private func handleText(_ provider: NSItemProvider) {
        let identifier = ShareAttachmentRouter.textTypeIdentifier(
            among: provider.registeredTypeIdentifiers)
        provider.loadItem(forTypeIdentifier: identifier) { [weak self] value, _ in
            guard let self else { return }
            self.cancelLoadWatchdog()
            let text = (value as? String)
                ?? (value as? NSAttributedString)?.string
                ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
            guard let text else {
                self.failOrComplete(L10n.string("ShareExtension_share_noLinkFoundMessage"))
                return
            }
            // A provider that can only show the file as a code block leaves
            // the user "long-press → Share" on the text. It is a Luna file
            // before it is a caption, so this runs before link extraction.
            if LunaFileIntake.looksLikeLunaFile(text: text),
               self.dispatchLunaFile(text: text, sourceURL: nil) {
                return
            }
            // A Facebook deep link (`fbrpc://…&target_url=…`) shared as
            // text is not a link `NSDataDetector` can detect, so this
            // unwraps it to its real http article first, falling back to
            // normal link extraction otherwise.
            if let extracted = Self.facebookTargetIfPresent(in: text)
                ?? ShareTextURL.extract(from: text)
                ?? ShareTextURL.firstLink(in: text),
               let url = URLUnwrapper.ingestURL(from: extracted.absoluteString) {
                if self.presentShareSetupPracticeIfNeeded(url) { return }
                SavesStore.shared.addIfAbsent(
                    urlString: url.absoluteString, source: .shareSheet)
                SharedDiagnosticLog.record(
                    "saved url (text) \(url.absoluteString)", category: "share")
                self.presentSavedOrReader(url: url)
                return
            }
            self.saveTextAsDocument(text)
        }
    }

    /// Imports a shared text payload that carries no link as a text
    /// document. The append copies synchronously, so the temp file is
    /// removed right after.
    private func saveTextAsDocument(_ text: String) {
        let fileName = Self.documentFileName(forSharedText: text)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        do {
            try text.write(to: temporaryURL, atomically: true, encoding: .utf8)
        } catch {
            SharedDiagnosticLog.record(
                "share: couldn't stage shared text as a document", category: "share")
            failOrComplete(L10n.string("ShareExtension_share_noLinkFoundMessage"))
            return
        }
        saveDocumentDirectly(sourceURL: temporaryURL)
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    /// The onboarding example is a rehearsal, not content. Both the share
    /// and action extension show the same bundled preview, record
    /// cross-process setup evidence, and leave the user's real saves list
    /// untouched.
    private func presentShareSetupPracticeIfNeeded(_ url: URL) -> Bool {
        guard ShareSetupPractice.matches(url) else { return false }
        let app = LunaApp.current
        if app.handlesProducts, ShareSetupPractice.matchesProductPractice(url) {
            presentProductSetupPractice(url)
            return true
        }
        // When hosted, this same preview is what the lesson shows the
        // user. Recording the run there would let the app complete its own
        // setup step on the user's behalf.
        if recordsSetupRunEvidence {
            LunaSetupStatusStore.shared.recordShareActionRun(isCentral: app == .luna)
        }
        SharedDiagnosticLog.record(
            "completed share-sheet onboarding practice", category: "share")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The Downloader's practice post is mock data flowing through
            // the same saved-media controller an action extension normally
            // shows. The kind module owns that controller, so the
            // kind-neutral share surface only asks its registered
            // presenter to mount it.
            if ShareSetupPractice.matchesVideoPractice(url),
               app.handlesMedia,
               let videoURL = ShareSetupPractice.bundledVideoURL,
               ShareKindPresenters.media?.presentPracticeVideo(
                    videoURL: videoURL, host: self) == true {
                return
            }
            let preview = Self.practicePreview(for: url, app: app)
            preview.completionDelegate = self
            self.presentModally(preview)
        }
        return true
    }

    /// The Price Tracker's fallback rehearsal is not a Reader preview. It
    /// appends the deterministic Amayzon product and hands a deterministic
    /// `ProductInfo` to the registered product presenter, so the hosted
    /// lesson and the real Price Tracker action extension both render the
    /// production price editor, including its Done chrome and
    /// seller-comparison state.
    private func presentProductSetupPractice(_ url: URL) {
        SavesStore.shared.addIfAbsent(
            urlString: url.absoluteString, source: .shareSheet)
        if let row = SavesStore.shared.item(forURLString: url.absoluteString) {
            HostedShareSession.current?.delegate?.hostedShareSessionDidAppendRow(row.id)
        }
        recordShareSurfaceRun()
        guard let presenter = ShareKindPresenters.product else {
            assertionFailure("Product practice reached a host without its product presenter")
            failOrComplete(L10n.string("ShareExtension_share_noLinkFoundMessage"))
            return
        }
        presenter.presentPriceEditor(
            product: Self.productSetupPracticeInfo,
            url: url,
            store: .shared,
            host: self)
    }

    /// Matches the product visible in the bundled Amayzon mock. This is only
    /// the no-weekly-save fallback; a live Save of the Week goes through the
    /// ordinary ingest pipeline and presents its own extracted product data.
    private static let productSetupPracticeInfo = ProductInfo(
        name: L10n.string("Onboarding_Demo_amayzonProductTitle"),
        priceAmount: 799,
        priceCurrency: "USD",
        imageURL: nil,
        brand: "Pearless",
        productID: "eyephone-air-256-moonmist")

    /// Which rehearsal a practice link stands for. The InstaTok link is a
    /// video post, and an app that downloads videos must rehearse
    /// downloading one, not show a page of prose that teaches the Reader's
    /// lesson instead. Everything else, and every bundle without the clip
    /// (see `ShareSetupPractice.bundledVideoURL`), keeps the article
    /// preview.
    private static func practicePreview(
        for url: URL, app: LunaApp
    ) -> UIViewController & ShareSetupPracticePresenting {
        guard ShareSetupPractice.matchesVideoPractice(url),
              app.handlesMedia,
              let videoURL = ShareSetupPractice.bundledVideoURL
        else { return ShareSetupPracticePreviewViewController(app: app) }
        return ShareSetupPracticeDownloadViewController(app: app, videoURL: videoURL)
    }

    /// The stored document's file name, and so its title, since
    /// `SavesStore.addImportedDocument` takes the title from the file
    /// name. The shared text's own first line beats the provider's
    /// generic "text".
    private static func documentFileName(forSharedText text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let title = firstLine
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            .trimmingCharacters(in: .whitespaces)
            .prefix(60)
        return "\(title.isEmpty ? L10n.string("ShareExtension_share_sharedTextFallbackTitle") : String(title)).txt"
    }

    /// The http article inside a Facebook deep link when the shared text
    /// is such a link (`fbrpc://…&target_url=…`), else nil. `NSDataDetector`
    /// cannot see the non-http `fbrpc` scheme, so normal link extraction
    /// misses it.
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
                self.failOrComplete(L10n.string("ShareExtension_share_missingFileMessage"))
                return
            }
            // The router matches a Luna file by identifier, so this only
            // catches one the host advertised as plain text.
            if type.conforms(to: .text),
               case .success(let text) = LunaFileReader.readText(at: url),
               LunaFileIntake.looksLikeLunaFile(text: text),
               self.dispatchLunaFile(text: text, sourceURL: url) {
                return
            }
            // A text file that is essentially just a link imports as the
            // link, not the file, dropping the surrounding text.
            if type.conforms(to: .text),
               let contents = try? String(contentsOf: url, encoding: .utf8),
               let extracted = ShareTextURL.extract(from: contents),
               let normalized = URLUnwrapper.ingestURL(from: extracted.absoluteString) {
                SavesStore.shared.addIfAbsent(
                    urlString: normalized.absoluteString, source: .shareSheet)
                SharedDiagnosticLog.record(
                    "saved url (text file) \(normalized.absoluteString)", category: "share")
                self.presentSavedOrReader(url: normalized)
                return
            }
            self.saveDocumentDirectly(sourceURL: url)
        }
    }

    // MARK: - Luna files

    /// A Luna file shared as a file (`claudedocs/luna-file.md`). The system
    /// deletes the provider's copy when this callback returns, so the text is
    /// read here rather than later.
    private func handleLunaFile(_ provider: NSItemProvider, typeIdentifier: String) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, _ in
            guard let self else { return }
            self.cancelLoadWatchdog()
            guard let url else {
                self.failOrComplete(L10n.string("ShareExtension_share_missingFileMessage"))
                return
            }
            switch LunaFileReader.readText(at: url) {
            case .success(let text):
                if self.dispatchLunaFile(text: text, sourceURL: url) { return }
                self.failOrComplete(L10n.string("LunaFile_notALunaFileMessage"))
            case .failure(let error):
                self.failOrComplete(error.message)
            }
        }
    }

    /// Hands a Luna file to this surface's intake witness, or refuses it on the
    /// card the extensions already show for a foreign save. False means `text`
    /// is not a Luna file at all, and the caller carries on with its own route.
    @discardableResult
    private func dispatchLunaFile(text: String, sourceURL: URL?) -> Bool {
        guard let outcome = LunaFileIntake.classify(text: text) else { return false }
        switch outcome {
        case .success(.recovery(let file)):
            switch SurfaceSupport.evaluateForCurrentProcess(owner: file.kind.owningApp) {
            case .supported:
                SharedDiagnosticLog.record(
                    "luna file: recovery \(file.kind.rawValue) for \(file.url.absoluteString)",
                    category: "share")
                DispatchQueue.main.async {
                    LunaFileIntake.recoveryHandler?.handleRecovery(file, sourceURL: sourceURL)
                }
            case .unsupported(let owner):
                SharedDiagnosticLog.record("luna file: dropped foreign-kind recovery", category: "share")
                presentUnsupportedLunaFile(owner: owner, message: nil)
            }
        case let .success(.plugin(headerJSON, source)):
            // Only the central Luna app runs plugins; a sibling app links none
            // of the platform, so it can only say so.
            guard LunaApp.current == .luna else {
                SharedDiagnosticLog.record("luna file: dropped plugin draft", category: "share")
                presentUnsupportedLunaFile(
                    owner: .luna, message: L10n.string("UnsupportedSave_pluginFileMessage"))
                break
            }
            SharedDiagnosticLog.record("luna file: plugin draft", category: "share")
            DispatchQueue.main.async {
                LunaFileIntake.pluginHandler?.handlePlugin(source: source, headerJSON: headerJSON)
            }
        case .failure(let error):
            SharedDiagnosticLog.record("luna file refused: \(error)", category: "share")
            failOrComplete(error.message)
        }
        return true
    }

    private func presentUnsupportedLunaFile(owner: LunaApp, message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let card = UnsupportedSaveCardViewController(
                owner: owner, currentApp: .current, ownerMessage: message)
            card.delegate = self
            self.presentModally(card)
        }
    }

    /// The direct document-save path. Imported files never route through
    /// `ShareSurfaceDriver` — no classification is needed, since a file is
    /// already a `.document` — so the per-app content gate runs here
    /// instead. Documents belong to Luna Reader, so only Reader and the
    /// central Luna app accept them. A dropped document is checked before
    /// appending, so it never copies its file into the App Group at all;
    /// there is nothing to clean up. This stays synchronous up to the
    /// append, since the system deletes the source file when the provider
    /// callback returns, so the copy cannot be deferred.
    private func saveDocumentDirectly(sourceURL: URL) {
        switch SurfaceSupport.evaluateForCurrentProcess(owner: .reader) {
        case .supported:
            SavesStore.shared.addImportedDocument(sourceURL: sourceURL)
            SharedDiagnosticLog.record(
                "saved document \(sourceURL.lastPathComponent)", category: "share")
            completeAfterDirectSave()
        case .unsupported(let owner):
            SharedDiagnosticLog.record(
                "dropped foreign-kind document save", category: "share")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let error = UnsupportedSaveCardViewController(
                    owner: owner, currentApp: .current)
                error.delegate = self
                self.presentModally(error)
            }
        }
    }

    fileprivate func complete() {
        DispatchQueue.main.async { [weak self] in self?.finishRequest() }
    }

    /// The single completion chokepoint: idempotent, so the watchdog
    /// firing alongside a slow callback cannot double-complete, and always
    /// cancels the watchdog. Main thread only.
    private func finishRequest() {
        guard !hasCompleted else { return }
        hasCompleted = true
        cancelLoadWatchdog()
        // When hosted, "the request is complete" is the host's business,
        // not `NSExtensionContext`'s, and `extensionContext` is nil in-app
        // anyway. This still shares the one chokepoint, so it still
        // happens at most once.
        if let hostedFinish {
            HostedShareSession.current?.delegate?.hostedShareSessionReachedTerminal()
            hostedFinish()
            return
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Shows a brief liquid-glass "Saved" checkmark, then completes. Call
    /// only after an actual save, when no reader is being presented.
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

    /// Best-effort deep link into the containing app, for the
    /// rescue-failure card's "Finish in Luna" step. Extensions have no
    /// `UIApplication.shared`; `extensionContext.open` is the sanctioned,
    /// if not universally honored, route, and the card always shows
    /// manual fallback instructions too.
    public func openURL(_ url: URL) {
        extensionContext?.open(url, completionHandler: nil)
    }

    public func openURL(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard let extensionContext else {
            completion(false)
            return
        }
        extensionContext.open(url) { accepted in
            DispatchQueue.main.async { completion(accepted) }
        }
    }

    /// Opening the URL and completing must be sequenced through the extension
    /// context. Completing immediately after `open` can tear down the request
    /// before the source app (notably YouTube opening YouTube) handles it.
    public func openURLThenComplete(_ url: URL) {
        guard let extensionContext else {
            completeSilently()
            return
        }
        extensionContext.open(url) { [weak self] _ in
            // Closing is unconditional: even a denied/open-to-self handoff must
            // not strand the action/share extension on screen.
            self?.completeSilently()
        }
    }

    private func completeAfterDirectSave() {
        if isActionExtension {
            confirmSavedThenComplete()
        } else {
            completeSilently()
        }
    }

    /// When auto-download is on for the shared link's platform, hands the
    /// media download to the system background-transfer service and Live
    /// Activity before dismissing. The extension process is deliberately
    /// not the owner of the transfer, since it may be killed as soon as
    /// this request completes. The handoff itself comes from the
    /// registered media presenter (`ShareKindPresenters`, kind-neutral
    /// here); no presenter, or auto-download off, means there is nothing
    /// to start, so this just confirms the save, matching a non-media app.
    public func autoDownloadThenComplete(urlString: String) {
        cancelLoadWatchdog()
        guard let media = ShareKindPresenters.media, media.shouldAutoDownload(urlString: urlString) else {
            confirmSavedThenComplete()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let downloading = self.showDownloadingBadge(
                text: L10n.string("ShareExtension_share_startingDownloadStatus"))
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

    /// A liquid-glass badge with a spinner and label, returned so it can
    /// be swapped for the saved checkmark once the in-flight work
    /// finishes.
    @discardableResult
    private func showDownloadingBadge(
        text: String = L10n.string("ShareExtension_share_savingMediaStatus")
    ) -> UIVisualEffectView {
        let badge = UIVisualEffectView(effect: GlassStyle.barEffect())
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 24
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true

        let spinner = HorizonSpinnerView(side: 36)
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
            self?.failOrComplete(L10n.string("ShareExtension_share_loadTimeoutMessage"))
        }
        loadWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: work)
    }

    private func cancelLoadWatchdog() {
        loadWatchdog?.cancel()
        loadWatchdog = nil
    }

    /// The sheet-wide exit gesture is deliberately limited to the
    /// Downloader and Price Tracker's real extensions. Reader share/action
    /// extensions, and the in-app onboarding rehearsal, keep their own
    /// dismissal behavior.
    private var supportsSwipeDownDismissal: Bool {
        guard !isHosted else { return false }
        switch LunaApp.current {
        case .downloader, .priceTracker:
            return true
        case .luna, .reader, .vault, .writer:
            return false
        }
    }

    private func configureSwipeDownDismissal(
        on navigationController: ExtensionNavigationController
    ) {
        guard supportsSwipeDownDismissal else { return }
        navigationController.allowsSwipeDownToDismiss = true
        navigationController.swipeDismissDelegate = self
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
        label.text = L10n.string("Common_saved")
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

/// `ShareViewController` is the real `ExtensionHost`: a thin adapter over
/// the live `NSExtensionContext` and UIKit chrome. All ingest-and-present
/// decisions live in the host-agnostic `ShareSurfaceDriver`, testable with
/// a fake host; this conformance only surfaces the per-surface data
/// (`isActionExtension`/`readerMode`) and the real side effects: presenting
/// a modal, completing, and the confirmation/error chrome.
extension ShareViewController: ExtensionHost {

    /// The reader mode to present, or nil to save silently. This is fixed
    /// behavior, with no in-app setting: the share extension always saves
    /// and dismisses, while the "Read in Luna" action extension always
    /// opens the reader, in whichever mode it was last used in (state
    /// local to the extension).
    public var readerMode: ExtensionReaderMode? {
        isActionExtension ? ActionReaderMode.last : nil
    }

    /// The share extension presents normally. The action extension keeps
    /// all of its screens inside one embedded navigation controller, so
    /// archive → reader does not create a second presentation that can
    /// dismiss the extension host.
    public func presentModally(_ viewController: UIViewController) {
        // A presented kind screen — reader, saved media, price editor,
        // rescue card, practice preview — is where the flow stops on its
        // own; every route out of one is a tap. An in-app host is told so
        // it can hold the sheet on it and then take it away itself.
        if isHosted {
            HostedShareSession.current?.delegate?.hostedShareSessionReachedTerminal()
        }
        if isActionExtension {
            // The wait screen is being replaced, so retire it instead of
            // leaving its spinner turning behind whatever comes next.
            loadingScreen?.stopWaiting()
            loadingScreen = nil
            hostInNavigation(viewController)
            return
        }
        let nav = ExtensionNavigationController(rootViewController: viewController)
        configureSwipeDownDismissal(on: nav)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    /// Puts `viewController` in the action extension's one navigation
    /// context, creating it on first use and replacing its root after
    /// that. Every action-extension screen goes through here, the wait
    /// screen included, which keeps a single header standing from the
    /// first frame to the last, instead of appearing only once the first
    /// "real" screen arrives.
    private func hostInNavigation(_ viewController: UIViewController) {
        if let navigationController = actionNavigationController {
            navigationController.setViewControllers([viewController], animated: false)
            return
        }
        let navigationController = ExtensionNavigationController(
            rootViewController: viewController)
        configureSwipeDownDismissal(on: navigationController)
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
    }
}

/// The wait screen's header exit completes the request, same as Done.
extension ShareViewController: ExtensionLoadingExitDelegate {
    public func extensionLoadingViewControllerDidExit(
        _ screen: ExtensionLoadingViewController
    ) {
        complete()
    }
}

extension ShareViewController: ShareSetupPracticeDelegate {
    /// A rehearsal saved nothing, so its Done completes without the
    /// saved-checkmark chrome.
    func shareSetupPracticeDidFinish(_ practice: UIViewController) {
        completeSilently()
    }
}

/// A sheet-wide swipe down exits on the same completion path as Done/Close,
/// including cancelling any attachment-load watchdog before the request is
/// finished.
extension ShareViewController: ExtensionSwipeDismissDelegate {
    public func extensionNavigationControllerDidSwipeToDismiss(
        _ navigationController: ExtensionNavigationController
    ) {
        completeSilently()
    }
}
