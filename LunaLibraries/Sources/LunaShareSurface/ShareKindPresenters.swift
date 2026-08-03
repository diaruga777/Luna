//
//  ShareKindPresenters.swift
//  LunaShareSurface
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaStorage
import UIKit

/// The reader mode an extension surface presents its in-sheet reader in.
/// Kind-neutral (extension chrome data, not reader code) so the host protocol
/// and `ActionReaderMode` persistence stay in LunaShareSurface while the reader
/// itself lives in the article-kind module (`ShareReaderViewController`,
/// LunaReaderUI).
public enum ExtensionReaderMode: String {
    case reader, rsvp, chunk

    public var readerMode: ReadingListItem.ReaderMode {
        switch self {
        case .reader: return .scroll
        case .rsvp: return .rsvp
        case .chunk: return .highlight
        }
    }

    public init(readerMode: ReadingListItem.ReaderMode) {
        switch readerMode {
        case .scroll: self = .reader
        case .rsvp: self = .rsvp
        case .highlight: self = .chunk
        // The action extension never persists a page archive, so its closest
        // equivalent is the standard local reader.
        case .original: self = .reader
        }
    }
}

/// Article-kind presentation for the extension surfaces: the in-sheet reader,
/// the archive-CAPTCHA reader, and the extension-context article-save extras
/// (audio script / web archive / cover thumbnail). Implemented by
/// `ExtensionArticlePresenter` (LunaReaderUI).
@MainActor
public protocol ShareArticlePresenting {
    /// The extension-context extras after an article save (the store write
    /// itself stays in the driver): heuristics-only audio script, best-effort
    /// web archive, and the cover thumbnail — all no-ops on empty `html`
    /// exactly as before.
    func persistArticleExtras(
        item: ReadingListItem, content: ArticleContent, html: String, url: URL,
        store: ReadingListStore)

    /// Presents the in-sheet article reader (action extension).
    func presentReader(url: URL, mode: ExtensionReaderMode, outcome: Outcome, host: ExtensionHost)

    /// Presents the archive-CAPTCHA reader for a paywalled article whose row
    /// (`itemID`) the driver has already marked `.needsCaptcha`.
    func presentArchive(url: URL, itemID: UUID, store: ReadingListStore, host: ExtensionHost)
}

/// Media-kind presentation for the extension surfaces: the saved-non-textual
/// screen and the auto-download handoff. Implemented by
/// `ExtensionMediaPresenter` (LunaMediaDownload).
@MainActor
public protocol ShareMediaPresenting {
    /// Routes a saved video/social item: the saved-content screen when the
    /// surface is interactive or the platform is downloadable, else the
    /// silent auto-download/confirm terminal (`host.autoDownloadThenComplete`).
    func presentNonTextual(urlString: String, host: ExtensionHost)

    /// Whether a background auto-download should start for `urlString` (the
    /// setting is on and the platform is downloadable). Consulted by the
    /// host's `autoDownloadThenComplete`; false means just confirm the save.
    func shouldAutoDownload(urlString: String) -> Bool

    /// The background auto-download handoff for `urlString`: hands the media
    /// download to the system background-transfer service and Live Activity.
    func startAutoDownload(urlString: String) async

    /// Starts fetching `urlString`'s media NOW, before any screen asks for it,
    /// so a surface opened moments later finds the file already on disk. Used by
    /// the onboarding save lesson, which knows its link the instant the user taps
    /// into it but does not mount the surface until its sheet is sliding up.
    func preloadDownload(forURLString urlString: String)

    /// Removes everything the media kind persisted for `urlString`. The
    /// onboarding lesson's rehearsal has to leave the library exactly as it found
    /// it, and it cannot name `SavedMediaStore` itself — the shared app shell
    /// compiles into apps that link no media module at all.
    func deleteSavedContents(forURLString urlString: String)
}

/// Both of these are asks from ONE caller (the onboarding save lesson) that most
/// media presenters have no work for, so they default to nothing rather than
/// forcing every conformance to say so.
extension ShareMediaPresenting {
    public func preloadDownload(forURLString urlString: String) {}
    public func deleteSavedContents(forURLString urlString: String) {}
}

/// Product-kind presentation for the extension surfaces: persist the tracker
/// and present the price-tracking editor. Implemented by
/// `ExtensionProductPresenter` (LunaPriceUI).
@MainActor
public protocol ShareProductPresenting {
    /// Persists the tracker for the classified product page (into the driver's
    /// `store`), then presents the SAME price-tracking editor as the main app
    /// in the host's modal chrome (`confirmSavedThenComplete` if there is no
    /// row to attach it to).
    func presentPriceEditor(product: ProductInfo, url: URL, store: ReadingListStore, host: ExtensionHost)
}

/// The per-kind EXTENSION-PRESENTER registry, mirror of `IngestKindProcessors`
/// (LunaIngest) and `IngestorKindHandlers` (LunaReadingList): each extension
/// target's principal class (`ShareEntry+*` / `ActionEntry+*`) registers
/// exactly the presenters its host app's kinds need, so LunaShareSurface
/// itself links NO kind-specific module. `ShareSurfaceDriver.present` consults
/// it AFTER the `SurfaceSupport` gate — a registered kind reached without a
/// presenter is a programming error (the gate dropped foreign kinds first).
@MainActor
public enum ShareKindPresenters {
    public static var article: ShareArticlePresenting?
    public static var media: ShareMediaPresenting?
    public static var product: ShareProductPresenting?
}
