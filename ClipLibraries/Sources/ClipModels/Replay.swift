//
//  Replay.swift
//  ReaderKit
//

import Foundation

/// A diagnostic recording of EVERYTHING about ONE save: the initial input + its
/// source, an ordered list of typed events (every input, output, network
/// request/response, and intermediate pipeline decision), and the final
/// representation of the save (the formatted article content).
///
/// This is a CONTRACT consumed by downstream agents (an integration-test harness
/// that replays a `Replay` through the app, and a price-tracking feature that must
/// stay Replay-compatible). It is a `Codable` value type and is VERSIONED via
/// `schemaVersion` so consumers can detect format changes.
///
/// MEDIA BYTES ARE EXCLUDED. Thumbnails, cover images, and video are recorded by
/// URL/metadata only — never as bytes. Text bodies (HTML, JSON) are stored
/// verbatim; non-media binary bodies are stored base64-encoded.
public struct Replay: Codable, Equatable {
    /// The schema version of THIS serialized replay. Bump when the shape changes.
    /// Consumers must check this before decoding `events`/`finalContent`.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var metadata: Metadata
    public var input: Input
    /// Every recorded event, in the order it happened. `index` is monotonically
    /// increasing from 0 and is the authoritative ordering (timestamps may collide
    /// at sub-millisecond resolution).
    public var events: [Event]
    /// The final representation of the save — the extracted, formatted article
    /// content — present only when the save reached a readable terminal state.
    public var finalContent: ArticleContent?

    public init(
        schemaVersion: Int = Replay.currentSchemaVersion,
        metadata: Metadata,
        input: Input,
        events: [Event] = [],
        finalContent: ArticleContent? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.input = input
        self.events = events
        self.finalContent = finalContent
    }

    /// The terminal disposition of a recorded save.
    public enum ReplayState: String, Codable, Equatable {
        /// Recording is still open (the save hasn't reached a terminal state). A
        /// serialized replay should rarely be `inProgress` — only if the process
        /// died mid-save before termination.
        case inProgress
        /// The save failed (any error, `.failed`, or a genuinely unreadable result).
        case failed
        /// The save reached its terminal readable UI state (content parsed & ready
        /// to display; any required unlock done; no further network expected).
        case success
        /// The user explicitly reported this save as buggy from a bug-report entry
        /// point. Terminal state and source content are preserved as-is.
        case userReported
    }

    /// Identity, timing, and disposition of the recording.
    public struct Metadata: Codable, Equatable {
        /// Stable id for this replay (also the export file's base name).
        public var id: UUID
        /// Terminal disposition. `inProgress` until `terminate` is called.
        public var state: ReplayState
        /// When recording began.
        public var createdAt: Date
        /// When recording terminated (nil while `inProgress`).
        public var terminatedAt: Date?
        /// The reading-list item's URL at termination — the headline used to list
        /// and look up replays. Updated if the pipeline repoints the item (unwrap).
        public var itemURLString: String
        /// The reading-list item id this save produced, when known.
        public var itemID: UUID?

        public init(id: UUID, state: ReplayState, createdAt: Date, terminatedAt: Date? = nil,
                    itemURLString: String, itemID: UUID? = nil) {
            self.id = id
            self.state = state
            self.createdAt = createdAt
            self.terminatedAt = terminatedAt
            self.itemURLString = itemURLString
            self.itemID = itemID
        }
    }

    /// The save's initial input and where it came from.
    public struct Input: Codable, Equatable {
        /// The URL string exactly as it entered the pipeline (before unwrap).
        public var initialURLString: String
        /// Where this save was captured from. Reuses the app's `CaptureSource`,
        /// extended with reader-internal sources (a link tapped inside a viewer).
        public var source: ReplaySource

        public init(initialURLString: String, source: ReplaySource) {
            self.initialURLString = initialURLString
            self.source = source
        }
    }

    /// One recorded event. `index` is the authoritative order.
    public struct Event: Codable, Equatable {
        public var index: Int
        public var timestamp: Date
        public var kind: EventKind

        public init(index: Int, timestamp: Date, kind: EventKind) {
            self.index = index
            self.timestamp = timestamp
            self.kind = kind
        }
    }
}

/// Where a save originated, for replay purposes. A superset of `CaptureSource`
/// that also names reader-internal origins (e.g. a link clicked inside another
/// save's viewer) and keeps a raw fallback so an unknown future `CaptureSource`
/// still round-trips.
public enum ReplaySource: Codable, Equatable {
    /// One of the app's standard capture sources (paste, share sheet, app intent,
    /// friend share, email, manual).
    case capture(CaptureSource)
    /// A link the user tapped inside the reader/viewer of another save (the split
    /// web overlay / inline reader). `parentURLString` is the save it came from.
    case linkInViewer(parentURLString: String)

    /// A flat, contract-friendly label for the source (used by consumers that
    /// don't want to switch on the enum).
    public var label: String {
        switch self {
        case let .capture(source): return source.rawValue
        case .linkInViewer: return "linkInViewer"
        }
    }

    // The encoding matches the documented `replays.md` contract exactly:
    //   {"capture": "manual"}                                  // a standard source
    //   {"linkInViewer": {"parentURLString": "https://…"}}      // a reader-internal link
    // A hand-authored replay (and the price-tracking consumer) relies on this flat
    // shape, so we spell out `Codable` rather than accept Swift's synthesized
    // associated-value wrapping (`{"capture":{"_0":"manual"}}`).

    private enum CodingKeys: String, CodingKey {
        case capture, linkInViewer
    }

    private struct LinkInViewerPayload: Codable {
        var parentURLString: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(String.self, forKey: .capture) {
            guard let source = CaptureSource(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .capture, in: container,
                    debugDescription: "Unknown CaptureSource \(raw)")
            }
            self = .capture(source)
        } else if let payload = try container.decodeIfPresent(
            LinkInViewerPayload.self, forKey: .linkInViewer) {
            self = .linkInViewer(parentURLString: payload.parentURLString)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .capture, in: container,
                debugDescription: "ReplaySource has neither a capture nor a linkInViewer key")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .capture(source):
            try container.encode(source.rawValue, forKey: .capture)
        case let .linkInViewer(parentURLString):
            try container.encode(
                LinkInViewerPayload(parentURLString: parentURLString), forKey: .linkInViewer)
        }
    }
}

/// The typed payload of a `Replay.Event`. Encoded with an internal `type`
/// discriminator (e.g. `{"type":"networkRequest", …}`) so consumers can branch on
/// `type` without Swift.
public enum EventKind: Codable, Equatable {
    /// An outgoing HTTP request (full URL/method/headers/body).
    case networkRequest(NetworkRequest)
    /// An HTTP response (full status/headers/body; `error` set on transport failure).
    case networkResponse(NetworkResponse)
    /// A news-aggregator wrapper was unwrapped to the real publisher article.
    case unwrap(fromURLString: String, toURLString: String)
    /// The resolver decided the article's disposition (readable/paywalled/unreadable).
    case resolveDecision(ResolveOutcome)
    /// A silent or WKWebView bypass strategy was attempted.
    case bypassStrategy(name: String, runsSilently: Bool, succeeded: Bool)
    /// A stage of the WKWebView archive/bypass reader (loaded URL, challenge, etc.).
    case archiveStage(stage: String, urlString: String?, note: String?)
    /// An extraction produced article content (counts + readability verdict).
    case extraction(blockCount: Int, bodyTextLength: Int, title: String, hasReadableBody: Bool)
    /// The recorded save changed terminal state.
    case stateChange(Replay.ReplayState)
    /// A media reference recorded by URL/metadata only — bytes intentionally omitted.
    case mediaReference(role: String, urlString: String)
    /// A free-form diagnostic note.
    case note(String)

    /// The resolver's disposition, mirroring `ArticleResolution` without its
    /// associated content (the content lands in `finalContent`).
    public enum ResolveOutcome: String, Codable, Equatable {
        case readable
        case paywalled
        case unreadable
    }

    private enum CodingKeys: String, CodingKey {
        case type, request, response, fromURLString, toURLString, outcome
        case name, runsSilently, succeeded, stage, urlString, note
        case blockCount, bodyTextLength, title, hasReadableBody, state, role, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "networkRequest":
            self = .networkRequest(try container.decode(NetworkRequest.self, forKey: .request))
        case "networkResponse":
            self = .networkResponse(try container.decode(NetworkResponse.self, forKey: .response))
        case "unwrap":
            self = .unwrap(
                fromURLString: try container.decode(String.self, forKey: .fromURLString),
                toURLString: try container.decode(String.self, forKey: .toURLString))
        case "resolveDecision":
            self = .resolveDecision(try container.decode(ResolveOutcome.self, forKey: .outcome))
        case "bypassStrategy":
            self = .bypassStrategy(
                name: try container.decode(String.self, forKey: .name),
                runsSilently: try container.decode(Bool.self, forKey: .runsSilently),
                succeeded: try container.decode(Bool.self, forKey: .succeeded))
        case "archiveStage":
            self = .archiveStage(
                stage: try container.decode(String.self, forKey: .stage),
                urlString: try container.decodeIfPresent(String.self, forKey: .urlString),
                note: try container.decodeIfPresent(String.self, forKey: .note))
        case "extraction":
            self = .extraction(
                blockCount: try container.decode(Int.self, forKey: .blockCount),
                bodyTextLength: try container.decode(Int.self, forKey: .bodyTextLength),
                title: try container.decode(String.self, forKey: .title),
                hasReadableBody: try container.decode(Bool.self, forKey: .hasReadableBody))
        case "stateChange":
            self = .stateChange(try container.decode(Replay.ReplayState.self, forKey: .state))
        case "mediaReference":
            self = .mediaReference(
                role: try container.decode(String.self, forKey: .role),
                urlString: try container.decode(String.self, forKey: .urlString))
        case "note":
            self = .note(try container.decode(String.self, forKey: .text))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown EventKind type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .networkRequest(request):
            try container.encode("networkRequest", forKey: .type)
            try container.encode(request, forKey: .request)
        case let .networkResponse(response):
            try container.encode("networkResponse", forKey: .type)
            try container.encode(response, forKey: .response)
        case let .unwrap(from, to):
            try container.encode("unwrap", forKey: .type)
            try container.encode(from, forKey: .fromURLString)
            try container.encode(to, forKey: .toURLString)
        case let .resolveDecision(outcome):
            try container.encode("resolveDecision", forKey: .type)
            try container.encode(outcome, forKey: .outcome)
        case let .bypassStrategy(name, runsSilently, succeeded):
            try container.encode("bypassStrategy", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(runsSilently, forKey: .runsSilently)
            try container.encode(succeeded, forKey: .succeeded)
        case let .archiveStage(stage, urlString, note):
            try container.encode("archiveStage", forKey: .type)
            try container.encode(stage, forKey: .stage)
            try container.encodeIfPresent(urlString, forKey: .urlString)
            try container.encodeIfPresent(note, forKey: .note)
        case let .extraction(blockCount, bodyTextLength, title, hasReadableBody):
            try container.encode("extraction", forKey: .type)
            try container.encode(blockCount, forKey: .blockCount)
            try container.encode(bodyTextLength, forKey: .bodyTextLength)
            try container.encode(title, forKey: .title)
            try container.encode(hasReadableBody, forKey: .hasReadableBody)
        case let .stateChange(state):
            try container.encode("stateChange", forKey: .type)
            try container.encode(state, forKey: .state)
        case let .mediaReference(role, urlString):
            try container.encode("mediaReference", forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encode(urlString, forKey: .urlString)
        case let .note(text):
            try container.encode("note", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

/// A captured HTTP request. Headers and body are recorded in full; a body's
/// representation depends on its content (see `HTTPBody`).
public struct NetworkRequest: Codable, Equatable {
    public var urlString: String
    public var method: String
    public var headers: [String: String]
    public var body: HTTPBody?

    public init(urlString: String, method: String, headers: [String: String], body: HTTPBody?) {
        self.urlString = urlString
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// A captured HTTP response. `statusCode` is -1 on a transport error (with
/// `error` set). The body follows the same `HTTPBody` rules as a request.
public struct NetworkResponse: Codable, Equatable {
    public var urlString: String
    public var statusCode: Int
    public var headers: [String: String]
    public var body: HTTPBody?
    /// Transport-level error description (DNS, timeout, …), nil on an HTTP response.
    public var error: String?

    public init(urlString: String, statusCode: Int, headers: [String: String],
                body: HTTPBody?, error: String?) {
        self.urlString = urlString
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.error = error
    }
}

/// A request/response body. Text bodies (HTML, JSON, …) are stored verbatim;
/// non-media binary is base64-encoded; media bytes are NEVER stored (only a
/// reason marker — the media URL itself lives in the request/response `urlString`).
public enum HTTPBody: Codable, Equatable {
    /// A textual body, stored verbatim. `truncatedBytes` > 0 means the original
    /// was longer and was cut to bound memory/disk.
    case text(String, truncatedBytes: Int)
    /// A non-media binary body, base64-encoded.
    case base64(String)
    /// Body bytes intentionally omitted (e.g. media). `reason` explains why.
    case omitted(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, text, truncatedBytes, base64, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "text":
            self = .text(
                try container.decode(String.self, forKey: .text),
                truncatedBytes: try container.decodeIfPresent(Int.self, forKey: .truncatedBytes) ?? 0)
        case "base64":
            self = .base64(try container.decode(String.self, forKey: .base64))
        case "omitted":
            self = .omitted(reason: try container.decode(String.self, forKey: .reason))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown HTTPBody kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value, truncatedBytes):
            try container.encode("text", forKey: .kind)
            try container.encode(value, forKey: .text)
            if truncatedBytes > 0 { try container.encode(truncatedBytes, forKey: .truncatedBytes) }
        case let .base64(value):
            try container.encode("base64", forKey: .kind)
            try container.encode(value, forKey: .base64)
        case let .omitted(reason):
            try container.encode("omitted", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}
