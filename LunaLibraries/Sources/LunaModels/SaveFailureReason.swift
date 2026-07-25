//
//  SaveFailureReason.swift
//  LunaModels
//

import Foundation

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
    /// The response wasn't decodable as text/HTML (a binary body, or an
    /// encoding we can't read).
    case notHTML
    /// The server declared a body larger than Luna will hold in memory.
    case tooLarge
    /// A document save whose type Luna can't parse (`documentType`).
    case unsupportedDocument(String)
    /// A media link that resolved to no downloadable asset.
    case noMediaFound
    /// The extraction/persistence step itself failed (encode or disk write).
    case couldNotSave
    /// The site answered the article request by redirecting to its own subscribe /
    /// sign-in page, so the article was never served.
    case subscribeRedirect
    /// Nothing more specific was captured.
    case unknown

    /// One short sentence naming what went wrong — the failed card's headline
    /// detail line. Never blank, so the card always has something to say.
    public var headline: String {
        switch self {
        case .offline:
            return "No internet connection"
        case .timedOut:
            return "The site took too long to respond"
        case let .httpStatus(code):
            switch code {
            case 401, 403: return "The site refused the request (\(code))"
            case 404, 410: return "The page is gone (\(code))"
            case 429: return "The site is rate-limiting Luna (429)"
            case 500...599: return "The site had a server error (\(code))"
            default: return "The site answered with HTTP \(code)"
            }
        case let .network(detail):
            return detail
        case .notReadable:
            return "Nothing readable was found on the page"
        case .notHTML:
            return "The link isn't a readable web page"
        case .tooLarge:
            return "The page is too large to read"
        case let .unsupportedDocument(type):
            let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Luna can't read this document"
                : "Luna can't read .\(trimmed) documents"
        case .noMediaFound:
            return "No downloadable media was found"
        case .couldNotSave:
            return "Luna couldn't store the download"
        case .subscribeRedirect:
            return "The site sent Luna to its subscribe page"
        case .unknown:
            return "Luna couldn't fetch this link"
        }
    }

    /// A second line suggesting what the user can do, when there IS something.
    /// nil means the headline stands alone.
    public var suggestion: String? {
        switch self {
        case .offline:
            return "It will retry automatically once you're back online."
        case .timedOut, .network:
            return "Pull to retry, or open it in the browser below."
        case let .httpStatus(code):
            switch code {
            case 401, 403, 429:
                return "Opening it in the browser often works where a background fetch can't."
            case 404, 410:
                return "The page may have moved — try the browser to check."
            case 500...599:
                return "The site's problem, not yours. Retry in a little while."
            default:
                return "Pull to retry, or open it in the browser below."
            }
        case .notReadable, .notHTML:
            return "Apple Intelligence can sometimes pull an article out anyway."
        case .subscribeRedirect:
            return "Open it in the browser below to read it there."
        case .tooLarge, .unsupportedDocument, .noMediaFound, .couldNotSave, .unknown:
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
        case .notReadable, .notHTML, .tooLarge, .unsupportedDocument, .noMediaFound,
             .subscribeRedirect, .unknown:
            return false
        }
    }
}
