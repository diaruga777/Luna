//
//  PluginModelResolution.swift
//  LunaModels
//
//  A decoded Model keeps a relative URL exactly as the plugin wrote it. The
//  ingest stage resolves every one of them against the save's URL before an
//  adopter sees the Model, so no kind module ever handles a half-URL.
//
//  The value initializers here exist for the same reason: the decoders are the
//  only other way to build a Model, so a stage rebuilding one with resolved
//  URLs — and a test scripting one — would otherwise have to round-trip JSON.
//

import Foundation

// MARK: - Resolution

public extension PluginModel {
    /// The same Model with every URL made absolute against `base`. An already
    /// absolute URL is unchanged.
    func resolvingRelativeURLs(against base: URL) -> PluginModel {
        switch self {
        case let .media(model): return .media(model.resolvingRelativeURLs(against: base))
        case let .article(model): return .article(model.resolvingRelativeURLs(against: base))
        case let .product(model): return .product(model.resolvingRelativeURLs(against: base))
        }
    }
}

/// Makes one plugin-written URL absolute. A URL that already carries a scheme
/// is returned as written; anything else is read as a reference relative to
/// `base`, which is the ingest input's own URL.
public func pluginAbsoluteURL(_ url: URL?, base: URL) -> URL? {
    guard let url else { return nil }
    if url.scheme != nil { return url }
    return URL(string: url.relativeString, relativeTo: base)?.absoluteURL ?? url
}

public extension MediaAssetSpec {
    func resolvingRelativeURLs(against base: URL) -> MediaAssetSpec {
        MediaAssetSpec(
            url: pluginAbsoluteURL(url, base: base) ?? url,
            type: type,
            audioURL: pluginAbsoluteURL(audioURL, base: base),
            dashManifestURL: pluginAbsoluteURL(dashManifestURL, base: base),
            thumbnailURL: pluginAbsoluteURL(thumbnailURL, base: base),
            estimatedBytes: estimatedBytes,
            headers: headers,
            timeRange: timeRange,
            quality: quality)
    }
}

public extension MediaModel {
    func resolvingRelativeURLs(against base: URL) -> MediaModel {
        MediaModel(
            title: title, author: author,
            thumbnailURL: pluginAbsoluteURL(thumbnailURL, base: base),
            platform: platform, itemID: itemID,
            assets: assets.map { $0.resolvingRelativeURLs(against: base) },
            expiresAt: expiresAt)
    }
}

public extension ArticleDocumentSpec {
    func resolvingRelativeURLs(against base: URL) -> ArticleDocumentSpec {
        ArticleDocumentSpec(
            url: pluginAbsoluteURL(url, base: base) ?? url, type: type, headers: headers)
    }
}

public extension ArticleModel {
    func resolvingRelativeURLs(against base: URL) -> ArticleModel {
        ArticleModel(
            title: title, author: author, publishedAt: publishedAt, html: html,
            baseURL: pluginAbsoluteURL(baseURL, base: base),
            leadImageURL: pluginAbsoluteURL(leadImageURL, base: base),
            excerpt: excerpt, language: language,
            document: document?.resolvingRelativeURLs(against: base))
    }
}

public extension ProductSellerSpec {
    func resolvingRelativeURLs(against base: URL) -> ProductSellerSpec {
        ProductSellerSpec(
            url: pluginAbsoluteURL(url, base: base) ?? url, name: name, price: price)
    }
}

public extension ProductModel {
    func resolvingRelativeURLs(against base: URL) -> ProductModel {
        ProductModel(
            name: name, price: price,
            imageURL: pluginAbsoluteURL(imageURL, base: base),
            brand: brand, productID: productID, identifiers: identifiers,
            sellers: sellers.map { $0.resolvingRelativeURLs(against: base) })
    }
}

// MARK: - Value initializers

public extension MediaAssetSpec {
    init(
        url: URL, type: AssetType, audioURL: URL? = nil, dashManifestURL: URL? = nil,
        thumbnailURL: URL? = nil, estimatedBytes: Int64? = nil,
        headers: [String: String] = [:], timeRange: TimeRange? = nil, quality: String? = nil
    ) {
        self.url = url
        self.type = type
        self.audioURL = audioURL
        self.dashManifestURL = dashManifestURL
        self.thumbnailURL = thumbnailURL
        self.estimatedBytes = estimatedBytes
        self.headers = headers
        self.timeRange = timeRange
        self.quality = quality
    }
}

public extension MediaModel {
    init(
        title: String? = nil, author: String? = nil, thumbnailURL: URL? = nil,
        platform: String? = nil, itemID: String? = nil, assets: [MediaAssetSpec],
        expiresAt: Date? = nil
    ) {
        self.title = title
        self.author = author
        self.thumbnailURL = thumbnailURL
        self.platform = platform
        self.itemID = itemID
        self.assets = assets
        self.expiresAt = expiresAt
    }
}

public extension ArticleDocumentSpec {
    init(url: URL, type: DocumentType, headers: [String: String] = [:]) {
        self.url = url
        self.type = type
        self.headers = headers
    }
}

public extension ArticleModel {
    init(
        title: String, author: String? = nil, publishedAt: String? = nil, html: String,
        baseURL: URL? = nil, leadImageURL: URL? = nil, excerpt: String? = nil,
        language: String? = nil, document: ArticleDocumentSpec? = nil
    ) {
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
        self.html = html
        self.baseURL = baseURL
        self.leadImageURL = leadImageURL
        self.excerpt = excerpt
        self.language = language
        self.document = document
    }
}

public extension ProductIdentifiersSpec {
    init(gtin: String? = nil, mpn: String? = nil, sku: String? = nil, brand: String? = nil) {
        self.gtin = gtin
        self.mpn = mpn
        self.sku = sku
        self.brand = brand
    }
}

public extension ProductSellerSpec {
    init(url: URL, name: String? = nil, price: PluginPrice? = nil) {
        self.url = url
        self.name = name
        self.price = price
    }
}

public extension ProductModel {
    init(
        name: String, price: PluginPrice, imageURL: URL? = nil, brand: String? = nil,
        productID: String? = nil, identifiers: ProductIdentifiersSpec? = nil,
        sellers: [ProductSellerSpec] = []
    ) {
        self.name = name
        self.price = price
        self.imageURL = imageURL
        self.brand = brand
        self.productID = productID
        self.identifiers = identifiers
        self.sellers = sellers
    }
}
