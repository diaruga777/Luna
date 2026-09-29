//
//  PluginModel.swift
//  LunaModels
//

import Foundation

/// The three kinds a plugin may return. Render is not pluggable: each kind maps
/// onto a renderer Luna already ships.
public enum PluginModelKind: String, Codable, Sendable, CaseIterable {
    case article
    case media
    case product
}

/// What a plugin returned from its `ingest` hook, decoded strictly.
///
/// The TypeScript in `claudedocs/plans/plugin-platform.md` §5 is the contract;
/// this type is its Swift half. Decoding is hand-written so every rejection
/// names the field that failed, and so a cap is enforced at the boundary rather
/// than trusted downstream.
///
/// **Relative URLs are not resolved here.** A plugin may return a path, and
/// `PluginIngestStage` resolves it against the ingest input's URL — this type
/// only refuses an ABSOLUTE URL whose scheme is neither http nor https.
public enum PluginModel: Decodable, Equatable, Sendable {
    case media(MediaModel)
    case article(ArticleModel)
    case product(ProductModel)

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try container.decodeIfPresent(String.self, forKey: .kind) else {
            throw PluginModelValidationError.missingField("kind")
        }
        guard let kind = PluginModelKind(rawValue: raw) else {
            throw PluginModelValidationError.unknownKind(raw)
        }
        switch kind {
        case .media: self = .media(try MediaModel(from: decoder))
        case .article: self = .article(try ArticleModel(from: decoder))
        case .product: self = .product(try ProductModel(from: decoder))
        }
    }

    public var kind: PluginModelKind {
        switch self {
        case .media: return .media
        case .article: return .article
        case .product: return .product
        }
    }
}

public extension PluginModelKind {
    /// Which standalone Luna app owns content of this kind — the same split
    /// `Outcome.owningApp` makes for a classified URL, so a Model arriving in a
    /// Luna file meets the same surface gate a saved link does.
    var owningApp: LunaApp {
        switch self {
        case .article: return .reader
        case .media: return .downloader
        case .product: return .priceTracker
        }
    }
}

// MARK: - Media

/// One downloadable asset a media plugin returned. The durable download engine
/// downloads these; a plugin never starts a transfer itself.
public struct MediaAssetSpec: Decodable, Equatable, Sendable {
    public enum AssetType: String, Decodable, Sendable {
        case video, image, gif, audio
    }

    /// A clip range the source asked for, in seconds from the asset's start.
    public struct TimeRange: Decodable, Equatable, Sendable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public let url: URL
    public let type: AssetType
    /// A separate audio leg to mux with `url` (Reddit and DASH sources).
    public let audioURL: URL?
    public let dashManifestURL: URL?
    public let thumbnailURL: URL?
    public let estimatedBytes: Int64?
    /// Sent on the download request. Only the allowlist in
    /// `PluginModelCaps.allowedHeaderNames` may appear.
    public let headers: [String: String]
    public let timeRange: TimeRange?
    /// Matches legs to one another when the engine re-resolves an expired URL.
    public let quality: String?

    private enum CodingKeys: String, CodingKey {
        case url, type, audioURL, dashManifestURL, thumbnailURL
        case estimatedBytes, headers, timeRange, quality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.requiredPluginURL(.url, field: "assets[].url")
        guard let rawType = try c.decodeIfPresent(String.self, forKey: .type) else {
            throw PluginModelValidationError.missingField("assets[].type")
        }
        guard let type = AssetType(rawValue: rawType) else {
            throw PluginModelValidationError.unknownKind(rawType)
        }
        self.type = type
        audioURL = try c.optionalPluginURL(.audioURL, field: "assets[].audioURL")
        dashManifestURL = try c.optionalPluginURL(.dashManifestURL, field: "assets[].dashManifestURL")
        thumbnailURL = try c.optionalPluginURL(.thumbnailURL, field: "assets[].thumbnailURL")
        estimatedBytes = try c.pluginByteCount(.estimatedBytes, field: "assets[].estimatedBytes")
        headers = try c.pluginHeaders(.headers)
        timeRange = try c.decodeIfPresent(TimeRange.self, forKey: .timeRange)
        quality = try c.optionalPluginString(
            .quality, field: "assets[].quality", cap: PluginModelCaps.shortString)
    }
}

public struct MediaModel: Decodable, Equatable, Sendable {
    public let title: String?
    public let author: String?
    public let thumbnailURL: URL?
    /// Free text. The stage maps a known name onto `ContentPlatform` and
    /// otherwise keeps the plugin id.
    public let platform: String?
    public let itemID: String?
    /// Display order, 1…50.
    public let assets: [MediaAssetSpec]
    /// Epoch seconds after which the asset URLs are stale and the engine
    /// re-runs the owning plugin.
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case title, author, thumbnailURL, platform, assets, expiresAt
        case itemID = "itemId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.optionalPluginString(.title, field: "title", cap: PluginModelCaps.title)
        author = try c.optionalPluginString(.author, field: "author", cap: PluginModelCaps.title)
        thumbnailURL = try c.optionalPluginURL(.thumbnailURL, field: "thumbnailURL")
        platform = try c.optionalPluginString(
            .platform, field: "platform", cap: PluginModelCaps.shortString)
        itemID = try c.optionalPluginString(
            .itemID, field: "itemId", cap: PluginModelCaps.shortString)
        let assets = try c.decodeIfPresent([MediaAssetSpec].self, forKey: .assets) ?? []
        guard (PluginModelCaps.assetCount).contains(assets.count) else {
            throw PluginModelValidationError.assetCountOutOfRange(assets.count)
        }
        self.assets = assets
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
            .map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - Article

/// A file an article plugin points at instead of, or beside, its HTML. The core
/// fetches it and imports it the way a shared document is imported.
public struct ArticleDocumentSpec: Decodable, Equatable, Sendable {
    public enum DocumentType: String, Decodable, Sendable {
        case pdf, epub, docx, rtf, html, md, txt
    }

    public let url: URL
    public let type: DocumentType
    public let headers: [String: String]

    private enum CodingKeys: String, CodingKey { case url, type, headers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.requiredPluginURL(.url, field: "document.url")
        guard let rawType = try c.decodeIfPresent(String.self, forKey: .type) else {
            throw PluginModelValidationError.missingField("document.type")
        }
        guard let type = DocumentType(rawValue: rawType) else {
            throw PluginModelValidationError.unknownKind(rawType)
        }
        self.type = type
        headers = try c.pluginHeaders(.headers)
    }
}

/// A recording an article plugin points at instead of HTML. The core downloads
/// it, transcribes it on device, and stores the transcript as the article;
/// the file is deleted afterwards (`claudedocs/plans/transcription-plugins.md`).
public struct ArticleTranscriptionSpec: Decodable, Equatable, Sendable {
    public enum MediaType: String, Decodable, Sendable {
        case audio, video
    }

    public let url: URL
    public let type: MediaType
    /// A separate audio leg for a video. When present, only this leg is fetched.
    public let audioURL: URL?
    /// Sent on the download request. Only the allowlist in
    /// `PluginModelCaps.allowedHeaderNames` may appear.
    public let headers: [String: String]
    /// Epoch seconds after which the URLs are stale and the runner re-runs the
    /// owning plugin before fetching.
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey { case url, type, audioURL, headers, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.requiredPluginURL(.url, field: "transcription.url")
        guard let rawType = try c.decodeIfPresent(String.self, forKey: .type) else {
            throw PluginModelValidationError.missingField("transcription.type")
        }
        guard let type = MediaType(rawValue: rawType) else {
            throw PluginModelValidationError.unknownKind(rawType)
        }
        self.type = type
        audioURL = try c.optionalPluginURL(.audioURL, field: "transcription.audioURL")
        headers = try c.pluginHeaders(.headers)
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
            .map { Date(timeIntervalSince1970: $0) }
    }
}

public struct ArticleModel: Decodable, Equatable, Sendable {
    public let title: String
    public let author: String?
    /// ISO 8601, as the plugin wrote it. The adopter parses it.
    public let publishedAt: String?
    /// The cleaned body fragment. The plugin already chose the body, so the
    /// adopter skips readability scoring.
    public let html: String
    public let baseURL: URL?
    public let leadImageURL: URL?
    public let excerpt: String?
    public let language: String?
    public let document: ArticleDocumentSpec?
    /// A recording to transcribe into the body. `html` may then be empty; when
    /// it is not, its blocks precede the transcript. Never present together
    /// with `document`.
    public let transcription: ArticleTranscriptionSpec?

    private enum CodingKeys: String, CodingKey {
        case title, author, publishedAt, html, baseURL, leadImageURL
        case excerpt, language, document, transcription
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.requiredPluginString(.title, field: "title", cap: PluginModelCaps.title)
        author = try c.optionalPluginString(.author, field: "author", cap: PluginModelCaps.title)
        publishedAt = try c.optionalPluginString(
            .publishedAt, field: "publishedAt", cap: PluginModelCaps.shortString)
        let transcription = try c.decodeIfPresent(ArticleTranscriptionSpec.self, forKey: .transcription)
        let document = try c.decodeIfPresent(ArticleDocumentSpec.self, forKey: .document)
        // A document or recording can supply the body without placeholder HTML.
        guard let html = try c.decodeIfPresent(String.self, forKey: .html)
            ?? (transcription == nil && document == nil ? nil : "")
        else {
            throw PluginModelValidationError.missingField("html")
        }
        guard html.utf8.count <= PluginModelCaps.html else {
            throw PluginModelValidationError.htmlTooLarge(html.utf8.count)
        }
        self.html = html
        self.transcription = transcription
        baseURL = try c.optionalPluginURL(.baseURL, field: "baseURL")
        leadImageURL = try c.optionalPluginURL(.leadImageURL, field: "leadImageURL")
        excerpt = try c.optionalPluginString(
            .excerpt, field: "excerpt", cap: PluginModelCaps.excerpt)
        language = try c.optionalPluginString(
            .language, field: "language", cap: PluginModelCaps.shortString)
        self.document = document
        if document != nil, transcription != nil {
            throw PluginModelValidationError.conflictingFields("document", "transcription")
        }
    }
}

// MARK: - Product

/// A price as the plugin wrote it: the amount is a decimal STRING, never a
/// float, so the digits the page showed survive the bridge.
public struct PluginPrice: Decodable, Equatable, Sendable {
    public let amount: Decimal
    public let currency: String

    private enum CodingKeys: String, CodingKey { case amount, currency }

    public init(amount: Decimal, currency: String) {
        self.amount = amount
        self.currency = currency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try c.decodeIfPresent(String.self, forKey: .amount) else {
            throw PluginModelValidationError.missingField("price.amount")
        }
        guard raw.count <= PluginModelCaps.shortString,
              let amount = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
        else {
            throw PluginModelValidationError.invalidPrice(raw)
        }
        self.amount = amount
        currency = try c.requiredPluginString(
            .currency, field: "price.currency", cap: PluginModelCaps.shortString)
    }
}

public struct ProductIdentifiersSpec: Decodable, Equatable, Sendable {
    public let gtin: String?
    public let mpn: String?
    public let sku: String?
    public let brand: String?

    private enum CodingKeys: String, CodingKey { case gtin, mpn, sku, brand }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gtin = try c.optionalPluginString(
            .gtin, field: "identifiers.gtin", cap: PluginModelCaps.shortString)
        mpn = try c.optionalPluginString(
            .mpn, field: "identifiers.mpn", cap: PluginModelCaps.shortString)
        sku = try c.optionalPluginString(
            .sku, field: "identifiers.sku", cap: PluginModelCaps.shortString)
        brand = try c.optionalPluginString(
            .brand, field: "identifiers.brand", cap: PluginModelCaps.shortString)
    }
}

/// One alternative seller. Present `sellers` means the plugin owns comparison
/// for this tracker and the Swift fan-out is skipped.
public struct ProductSellerSpec: Decodable, Equatable, Sendable {
    public let url: URL
    public let name: String?
    public let price: PluginPrice?

    private enum CodingKeys: String, CodingKey { case url, name, price }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.requiredPluginURL(.url, field: "sellers[].url")
        name = try c.optionalPluginString(
            .name, field: "sellers[].name", cap: PluginModelCaps.title)
        price = try c.decodeIfPresent(PluginPrice.self, forKey: .price)
    }
}

public struct ProductModel: Decodable, Equatable, Sendable {
    public let name: String
    public let price: PluginPrice
    public let imageURL: URL?
    public let brand: String?
    public let productID: String?
    public let identifiers: ProductIdentifiersSpec?
    public let sellers: [ProductSellerSpec]

    private enum CodingKeys: String, CodingKey {
        case name, price, imageURL, brand, identifiers, sellers
        case productID = "productId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.requiredPluginString(.name, field: "name", cap: PluginModelCaps.title)
        guard let price = try c.decodeIfPresent(PluginPrice.self, forKey: .price) else {
            throw PluginModelValidationError.missingField("price")
        }
        self.price = price
        imageURL = try c.optionalPluginURL(.imageURL, field: "imageURL")
        brand = try c.optionalPluginString(.brand, field: "brand", cap: PluginModelCaps.title)
        productID = try c.optionalPluginString(
            .productID, field: "productId", cap: PluginModelCaps.shortString)
        identifiers = try c.decodeIfPresent(ProductIdentifiersSpec.self, forKey: .identifiers)
        let sellers = try c.decodeIfPresent([ProductSellerSpec].self, forKey: .sellers) ?? []
        guard sellers.count <= PluginModelCaps.sellerCount else {
            throw PluginModelValidationError.tooManySellers(sellers.count)
        }
        self.sellers = sellers
    }
}

// MARK: - Caps and errors

/// The limits the decoder enforces. They exist so one plugin cannot spend the
/// whole process's memory or smuggle a header the fetch layer would honour.
public enum PluginModelCaps {
    public static let title = 300
    public static let shortString = 200
    public static let excerpt = 1_000
    /// A URL a plugin may write. Signed CDN links are long — a YouTube
    /// progressive stream carries its whole signature in the query — so this is
    /// far above the prose caps above.
    public static let url = 4_096
    public static let html = 4 * 1024 * 1024
    public static let assetCount = 1...50
    public static let sellerCount = 20
    /// The longest header VALUE a plugin may set. A signed cookie is long, so
    /// this is the URL cap rather than a prose cap.
    public static let headerValue = 4_096
    /// The only request headers a plugin may set. Compared case-insensitively.
    public static let allowedHeaderNames: Set<String> = [
        "user-agent", "referer", "cookie", "accept",
        "accept-language", "origin", "range",
    ]
    public static let allowedURLSchemes: Set<String> = ["http", "https"]
}

/// Why a returned Model was refused. Equatable so a test names the exact
/// rejection rather than "it threw".
public enum PluginModelValidationError: Error, Equatable {
    /// `kind`, an asset `type` or a document `type` Luna does not know.
    case unknownKind(String)
    case missingField(String)
    /// An absolute URL whose scheme is neither http nor https, or a string that
    /// is no URL at all.
    case invalidURL(field: String, value: String)
    case stringTooLong(field: String, limit: Int)
    case assetCountOutOfRange(Int)
    case tooManySellers(Int)
    case htmlTooLarge(Int)
    case disallowedHeader(String)
    /// A header value over `PluginModelCaps.headerValue`.
    case headerValueTooLong(String)
    /// A byte count a plugin wrote as a negative number.
    case negativeByteCount(field: String)
    /// `price.amount` did not parse as a decimal.
    case invalidPrice(String)
    /// Two fields that each supply the whole body were both present.
    case conflictingFields(String, String)
}

// MARK: - Decoding helpers

extension KeyedDecodingContainer {

    fileprivate func requiredPluginString(_ key: Key, field: String, cap: Int) throws -> String {
        guard let value = try decodeIfPresent(String.self, forKey: key) else {
            throw PluginModelValidationError.missingField(field)
        }
        guard value.count <= cap else {
            throw PluginModelValidationError.stringTooLong(field: field, limit: cap)
        }
        return value
    }

    fileprivate func optionalPluginString(_ key: Key, field: String, cap: Int) throws -> String? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value.count <= cap else {
            throw PluginModelValidationError.stringTooLong(field: field, limit: cap)
        }
        return value
    }

    /// A URL string the plugin wrote. A relative reference is kept as written —
    /// the ingest stage resolves it against the save's URL — so only an
    /// absolute URL's scheme is checked.
    fileprivate func requiredPluginURL(_ key: Key, field: String) throws -> URL {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else {
            throw PluginModelValidationError.missingField(field)
        }
        return try Self.pluginURL(raw, field: field)
    }

    fileprivate func optionalPluginURL(_ key: Key, field: String) throws -> URL? {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return try Self.pluginURL(raw, field: field)
    }

    private static func pluginURL(_ raw: String, field: String) throws -> URL {
        guard raw.count <= PluginModelCaps.url, let url = URL(string: raw) else {
            throw PluginModelValidationError.invalidURL(field: field, value: raw)
        }
        if let scheme = url.scheme,
           !PluginModelCaps.allowedURLSchemes.contains(scheme.lowercased()) {
            throw PluginModelValidationError.invalidURL(field: field, value: raw)
        }
        return url
    }

    /// A byte count a plugin wrote. A negative one is no size at all, and the
    /// download engine reads this as a progress denominator.
    fileprivate func pluginByteCount(_ key: Key, field: String) throws -> Int64? {
        guard let value = try decodeIfPresent(Int64.self, forKey: key) else { return nil }
        guard value >= 0 else {
            throw PluginModelValidationError.negativeByteCount(field: field)
        }
        return value
    }

    fileprivate func pluginHeaders(_ key: Key) throws -> [String: String] {
        guard let headers = try decodeIfPresent([String: String].self, forKey: key) else {
            return [:]
        }
        for (name, value) in headers {
            guard PluginModelCaps.allowedHeaderNames.contains(name.lowercased()) else {
                throw PluginModelValidationError.disallowedHeader(name)
            }
            guard value.count <= PluginModelCaps.headerValue else {
                throw PluginModelValidationError.headerValueTooLong(name)
            }
        }
        return headers
    }
}
