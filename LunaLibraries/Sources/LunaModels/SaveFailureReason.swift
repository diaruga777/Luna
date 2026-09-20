//
//  SaveFailureReason.swift
//  LunaModels
//

import Foundation

/// The copy every failed-save surface shares, so the in-app card, the extension
/// failure card, the list row, and the Downloader's failed-download card can't
/// drift into four different apologies for the same thing.
public enum FailedSaveCopy {
    /// The headline a surface uses when it has to name the failure in words
    /// (the card doesn't — it shows the page).
    public static var couldNotLoad: String {
        L10n.string("SaveFailure_couldntLoadPage")
    }

    /// The URL as the error card's URL bar shows it: scheme stripped, path and
    /// query kept, because *which* link broke is the point.
    ///
    /// Lives here rather than in `FailedSaveNaming` (LunaFetch) so the extension
    /// failure card can show the identical string without an extension linking
    /// the fetch tier.
    public static func displayURL(_ url: URL?, rawURLString: String? = nil) -> String {
        let text = url?.absoluteString ?? rawURLString ?? ""
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }
}

/// WHY a saved URL ended `.failed` — the detail a failed card shows under its
/// title so "Couldn't fetch this" stops being the whole story.
///
/// Lives in LunaModels (the lowest tier) so the pipeline that produces it, the
/// sidecar store that persists it, and the card UI that renders it can all name
/// it without depending on each other. Deliberately COARSE: each case maps to
/// one actionable sentence a reader can do something about, not to a stack of
/// internal error codes. Anything genuinely unclassifiable is `.unknown`, and
/// the card then falls back to the generic copy.
public enum SaveFailureReason: Equatable, Sendable, Codable {
    /// The device had no usable network connection.
    case offline
    /// The whole ingest budget elapsed (`IngestPipeline.processTimeout`) or a
    /// single request timed out.
    case timedOut
    /// The server answered, but not with success. 401/403 read as a block,
    /// 404/410 as gone, 429 as rate-limited, 5xx as a server fault.
    case httpStatus(Int)
    /// A transport-level failure that isn't plain offline (DNS, TLS, refused
    /// connection). `detail` is the localized description, already user-facing.
    case network(String)
    /// The page loaded but carried no article text and not even a usable title.
    case notReadable
    /// The page isn't a piece of content at all — a search-results page, a site
    /// homepage, or a section index. Distinct from `.notReadable`: nothing was
    /// missed and nothing can be recovered, because there is no single item on
    /// the page to save. The one reason that must never reach the archive tier
    /// or the LLM rescue (see `ListingPage`).
    case notContent
    /// The response wasn't decodable as text/HTML (a binary body, or an
    /// encoding we can't read).
    case notHTML
    /// The server declared a body larger than Luna will hold in memory.
    case tooLarge
    /// A media link that resolved to no downloadable asset.
    case noMediaFound
    /// The extraction/persistence step itself failed (encode or disk write).
    case couldNotSave
    /// The site answered the article request by redirecting to its own subscribe /
    /// sign-in page, so the article was never served.
    case subscribeRedirect
    /// A transcribe request that no plugin could serve: nothing on the page
    /// carries speech Luna can fetch.
    case noTranscriptSource
    /// The recording was fetched but could not be transcribed. `detail` is the
    /// user-facing sentence the runner already localized.
    case transcriptionFailed(String)
    /// Nothing more specific was captured.
    case unknown

    /// One short sentence naming what went wrong — the failed card's headline
    /// detail line. Never blank, so the card always has something to say.
    public var headline: String {
        switch self {
        case .offline:
            return L10n.string("SaveFailure_noInternet")
        case .timedOut:
            return L10n.string("SaveFailure_timedOut")
        case let .httpStatus(code):
            switch code {
            case 401, 403: return L10n.string("SaveFailure_refused", code)
            case 404, 410: return L10n.string("SaveFailure_gone", code)
            case 429: return L10n.string("SaveFailure_rateLimited")
            case 500...599: return L10n.string("SaveFailure_serverError", code)
            default: return L10n.string("SaveFailure_httpStatus", code)
            }
        case let .network(detail):
            return detail
        case .notReadable:
            return L10n.string("SaveFailure_nothingReadable")
        case .notContent:
            return L10n.string("SaveFailure_nothingToSave")
        case .notHTML:
            return L10n.string("SaveFailure_notReadableWebPage")
        case .tooLarge:
            return L10n.string("SaveFailure_tooLarge")
        case .noMediaFound:
            return L10n.string("SaveFailure_noMediaFound")
        case .couldNotSave:
            return L10n.string("SaveFailure_couldntStoreDownload")
        case .subscribeRedirect:
            return L10n.string("SaveFailure_sentToSubscribePage")
        case .noTranscriptSource:
            return L10n.string("SaveFailure_noTranscriptSource")
        case let .transcriptionFailed(detail):
            return L10n.string("SaveFailure_transcriptionFailed", detail)
        case .unknown:
            return L10n.string("SaveFailure_couldntFetchLink")
        }
    }

    /// A second line suggesting what the user can do, when there IS something.
    /// nil means the headline stands alone.
    public var suggestion: String? {
        switch self {
        case .offline:
            return L10n.string("SaveFailure_willRetryHint")
        case .timedOut, .network:
            return L10n.string("SaveFailure_pullToRetryHint")
        case let .httpStatus(code):
            switch code {
            case 401, 403, 429:
                return L10n.string("SaveFailure_openInBrowserHint")
            case 404, 410:
                return L10n.string("SaveFailure_mayHaveMovedHint")
            case 500...599:
                return L10n.string("SaveFailure_sitesProblemHint")
            default:
                return L10n.string("SaveFailure_pullToRetryHint")
            }
        case .notReadable, .notHTML:
            return L10n.string("SaveFailure_appleIntelligenceHint")
        case .notContent:
            return L10n.string("SaveFailure_searchResultsHint")
        case .subscribeRedirect:
            return L10n.string("SaveFailure_openInBrowserToReadHint")
        case .tooLarge, .noMediaFound, .couldNotSave, .noTranscriptSource,
             .transcriptionFailed, .unknown:
            return nil
        }
    }

    /// Whether retrying the SAME background fetch has a real chance — drives
    /// whether the card offers "Try Again" alongside the LLM rescue.
    public var isWorthRetrying: Bool {
        switch self {
        case .offline, .timedOut, .network, .couldNotSave:
            return true
        case let .httpStatus(code):
            return code == 429 || (500...599).contains(code)
        case .notReadable, .notContent, .notHTML, .tooLarge,
             .noMediaFound, .subscribeRedirect, .noTranscriptSource,
             .transcriptionFailed, .unknown:
            return false
        }
    }

    /// Whether a REAL BROWSER is a plausible way in where the background fetch was
    /// turned away — the machine-readable form of the advice `suggestion` already
    /// gives for these codes ("Opening it in the browser often works where a
    /// background fetch can't").
    ///
    /// True only for the client-refusal codes 401/403/429: those say "not you", which
    /// on a bot-mitigated front door (Vercel's `x-vercel-mitigated: challenge` answers
    /// 429, DataDome/Cloudflare 403) is a statement about the CLIENT, not the page.
    /// A WKWebView presents a real browser's TLS fingerprint and runs the challenge
    /// JS, so it routinely gets a 200 and the full article for a page URLSession
    /// cannot touch at all — measured on a free piratewires.com article that answered
    /// 429 to every silent strategy (plain, Googlebot UA, cookieless, jina) and 200
    /// on the first WKWebView load.
    ///
    /// Deliberately EXCLUDES 404/410 (the page is gone — no client can conjure it),
    /// 5xx (the site's own fault, including Cloudflare's 503 interstitial, which
    /// would otherwise park every real outage as recoverable), and every transport
    /// failure (offline/timeout/DNS is not a refusal).
    public var browserMayRecover: Bool {
        guard case let .httpStatus(code) = self else { return false }
        return code == 401 || code == 403 || code == 429
    }

    /// Whether the LLM rescue has anything to work with. False for `.notContent`
    /// and the two transcription reasons: every other failure is "we couldn't
    /// GET the article", which a model reading the page can sometimes fix,
    /// whereas a search-results or index page has no article to find, and a
    /// recording that would not transcribe has no page for a model to read. A
    /// rescue would spend the version's single attempt proving it
    /// (`claudedocs/failed-saves.md`).
    public var isWorthRescuing: Bool {
        switch self {
        case .notContent, .noTranscriptSource, .transcriptionFailed:
            return false
        case .offline, .timedOut, .httpStatus, .network, .notReadable, .notHTML,
             .tooLarge, .noMediaFound, .couldNotSave, .subscribeRedirect, .unknown:
            return true
        }
    }
}
