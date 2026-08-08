//
//  SellerComparisonDocument.swift
//  LunaPriceUI
//

import Foundation
import LunaFetch
import LunaModels
import LunaStorage

/// The comparison summary the Action Button intents hand back as their `media`:
/// ONE self-contained HTML file.
///
/// Self-contained is the whole requirement, and it comes from where the file
/// goes. A Shortcut result is Quick Looked, saved to Files, AirDropped, mailed —
/// contexts with no network, no base URL and no cache — so every byte it needs
/// is inside it: the CSS is inline, the product photo and the sellers' favicons
/// are `data:` URIs, and the price graph is inline SVG rather than an image, so
/// it stays sharp at any size and needs no rasterisation pass.
///
/// It renders in the READER's appearance, not Luna's: a plain
/// `prefers-color-scheme` pair, because this file is the only thing Luna ships
/// that is read outside Luna, where `LunaSkyTrait` means nothing and a page that
/// forces black onto a light Quick Look looks broken rather than considered.
///
/// `html(_:)` is pure over a value the caller assembles, so the structure is
/// assertable without the network the assets come from.
public enum SellerComparisonDocument {

    // MARK: - The value the page is rendered from

    /// One row of the seller table.
    public struct SellerRow: Equatable {
        public let name: String
        public let urlString: String
        /// Nil for a store that has never been priced — shown, because a seller
        /// Luna is watching and cannot currently read is a fact about the
        /// comparison, not an absence.
        public let price: Decimal?
        public let currency: String
        /// `data:` URI, or nil for a seller whose icon could not be fetched.
        public let faviconDataURI: String?

        public init(
            name: String, urlString: String, price: Decimal?, currency: String,
            faviconDataURI: String?
        ) {
            self.name = name
            self.urlString = urlString
            self.price = price
            self.currency = currency
            self.faviconDataURI = faviconDataURI
        }
    }

    public struct Content: Equatable {
        public let productName: String
        /// `data:` URI for the product photo, or nil.
        public let productImageDataURI: String?
        /// Rows in the order they are shown: cheapest first, then unpriced.
        public let sellers: [SellerRow]
        public let series: [PriceGraphPoint]
        public let displayCurrency: String
        public let generatedAt: Date

        public init(
            productName: String, productImageDataURI: String?, sellers: [SellerRow],
            series: [PriceGraphPoint], displayCurrency: String, generatedAt: Date
        ) {
            self.productName = productName
            self.productImageDataURI = productImageDataURI
            self.sellers = sellers
            self.series = series
            self.displayCurrency = displayCurrency
            self.generatedAt = generatedAt
        }
    }

    /// The file name a produced document carries into Shortcuts.
    public static func fileName(for productName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = productName.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Price comparison" : String(cleaned.prefix(60))
        return "\(base).html"
    }

    // MARK: - Assembling from a tracker

    /// Builds the page's content from a tracker, fetching the assets it needs.
    ///
    /// Cheapest-first ordering, with unpriced stores last: the document exists to
    /// answer "where is this cheapest right now", so the answer is the first row
    /// as well as the highlighted one.
    public static func content(
        for tracker: PriceTracker, articlesDirectory: URL, now: Date = Date(),
        faviconLoader: (URL) async -> Data? = { await FaviconFetcher().fetchIconData(forPageURL: $0) }
    ) async -> Content {
        let ordered = tracker.stores.sorted { lhs, rhs in
            switch (lhs.lastPrice, rhs.lastPrice) {
            case let (l?, r?): return l == r ? lhs.urlString < rhs.urlString : l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.urlString < rhs.urlString
            }
        }
        var rows: [SellerRow] = []
        for store in ordered {
            let url = URL(string: store.urlString)
            var favicon: String?
            if let url, let data = await faviconLoader(url) {
                favicon = dataURI(data, mimeType: mimeType(forImageData: data))
            }
            rows.append(SellerRow(
                name: sellerName(forURLString: store.urlString),
                urlString: store.urlString,
                price: store.lastPrice,
                currency: store.currency,
                faviconDataURI: favicon))
        }
        var imageURI: String?
        if let fileName = tracker.imageFileName,
           let data = try? Data(
            contentsOf: articlesDirectory.appendingPathComponent(fileName)) {
            imageURI = dataURI(data, mimeType: mimeType(forImageData: data))
        }
        return Content(
            productName: tracker.productName,
            productImageDataURI: imageURI,
            sellers: rows,
            series: PriceHistory.series(for: tracker, now: now),
            displayCurrency: tracker.displayCurrency,
            generatedAt: now)
    }

    /// The seller's display name: its registrable domain with the public suffix
    /// dropped and the first letter raised ("amazon.co.uk" → "Amazon"). The
    /// directory's own name is not reachable from a persisted tracker — it stores
    /// URLs, not seller ids — and a host is what the user recognises anyway.
    public static func sellerName(forURLString urlString: String) -> String {
        guard let host = URL(string: urlString)?.host else { return urlString }
        let domain = ProductIdentityMatching.registrableDomain(host)
        guard let label = domain.split(separator: ".").first, !label.isEmpty else { return host }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Writes the document to a temporary file and returns its URL, or nil when
    /// the tracker has nothing worth comparing (a single store is not a
    /// comparison).
    public static func write(
        for tracker: PriceTracker, articlesDirectory: URL, now: Date = Date()
    ) async -> URL? {
        guard tracker.stores.count > 1 else { return nil }
        let page = html(await content(
            for: tracker, articlesDirectory: articlesDirectory, now: now))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(fileName(for: tracker.productName))
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(page.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - The page

    /// The whole document, as a string. Pure.
    public static func html(_ content: Content) -> String {
        let lowest = content.sellers.compactMap(\.price).min()
        var body = ""
        if let uri = content.productImageDataURI {
            body += "<img class=\"hero\" src=\"\(escape(uri))\" alt=\"\">\n"
        }
        body += "<h1>\(escape(content.productName))</h1>\n"
        body += "<p class=\"stamp\">\(escape(L10n.string("PriceTrackerCompareDoc_01_updatedFormat", Self.stamp(content.generatedAt))))</p>\n"
        body += graphSection(content)
        body += sellerSection(content, lowest: lowest)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(content.productName))</title>
        <style>\(styleSheet)</style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>

        """
    }

    private static func sellerSection(_ content: Content, lowest: Decimal?) -> String {
        var html = "<h2>\(escape(L10n.string("PriceTrackerCompareDoc_02_sellersHeading")))</h2>\n"
        guard !content.sellers.isEmpty else {
            return html
                + "<p class=\"empty\">\(escape(L10n.string("PriceTrackerCompareDoc_05_noSellersCaption")))</p>\n"
        }
        html += "<ul class=\"sellers\">\n"
        for row in content.sellers {
            let isLowest = row.price != nil && row.price == lowest
            html += "<li class=\"seller\(isLowest ? " lowest" : "")\">"
            html += "<a href=\"\(escape(row.urlString))\">"
            if let favicon = row.faviconDataURI {
                html += "<img class=\"icon\" src=\"\(escape(favicon))\" alt=\"\">"
            } else {
                html += "<span class=\"icon placeholder\"></span>"
            }
            html += "<span class=\"name\">\(escape(row.name))</span>"
            if isLowest {
                html += "<span class=\"badge\">"
                    + escape(L10n.string("PriceTrackerCompareDoc_03_lowestBadge")) + "</span>"
            }
            if let price = row.price {
                html += "<span class=\"price\">"
                    + escape(PriceFormatting.string(amount: price, currency: row.currency))
                    + "</span>"
            } else {
                html += "<span class=\"price none\">"
                    + escape(L10n.string("PriceTrackerCompareDoc_04_noPriceValue")) + "</span>"
            }
            html += "</a></li>\n"
        }
        return html + "</ul>\n"
    }

    private static func graphSection(_ content: Content) -> String {
        var html = "<h2>\(escape(L10n.string("PriceTrackerCompareDoc_06_historyHeading")))</h2>\n"
        guard content.series.count >= 2 else {
            return html
                + "<p class=\"empty\">\(escape(L10n.string("PriceTrackerCompareDoc_07_noHistoryCaption")))</p>\n"
        }
        return html + graphSVG(content) + "\n"
    }

    // MARK: - The graph

    static let graphWidth: Double = 640
    static let graphHeight: Double = 260
    private static let inset = (left: 58.0, right: 16.0, top: 16.0, bottom: 34.0)

    /// The price series as inline SVG, with a labelled price axis and a labelled
    /// date axis.
    ///
    /// A flat series (every point the same price) is a real state and must not
    /// divide by zero: it is drawn as a line through the middle of the plot,
    /// which is what a price that never moved looks like.
    static func graphSVG(_ content: Content) -> String {
        let points = content.series
        let prices = points.map { NSDecimalNumber(decimal: $0.price).doubleValue }
        let minPrice = prices.min() ?? 0
        let maxPrice = prices.max() ?? 0
        let span = maxPrice - minPrice
        let plotWidth = graphWidth - inset.left - inset.right
        let plotHeight = graphHeight - inset.top - inset.bottom

        func x(_ index: Int) -> Double {
            guard points.count > 1 else { return inset.left + plotWidth / 2 }
            return inset.left + plotWidth * Double(index) / Double(points.count - 1)
        }
        func y(_ price: Double) -> Double {
            guard span > 0 else { return inset.top + plotHeight / 2 }
            return inset.top + plotHeight * (1 - (price - minPrice) / span)
        }

        let path = prices.enumerated()
            .map { "\($0.offset == 0 ? "M" : "L")\(round2(x($0.offset))) \(round2(y($0.element)))" }
            .joined(separator: " ")
        let area = path
            + " L\(round2(x(points.count - 1))) \(round2(inset.top + plotHeight))"
            + " L\(round2(x(0))) \(round2(inset.top + plotHeight)) Z"

        var svg = "<svg class=\"graph\" viewBox=\"0 0 \(Int(graphWidth)) \(Int(graphHeight))\""
            + " role=\"img\" xmlns=\"http://www.w3.org/2000/svg\">"
        // Price axis: the two extremes plus the midpoint, which is all a series
        // this small can label without the numbers colliding.
        for (fraction, price) in [(0.0, maxPrice), (0.5, (maxPrice + minPrice) / 2), (1.0, minPrice)] {
            let gridY = inset.top + plotHeight * fraction
            svg += "<line class=\"grid\" x1=\"\(round2(inset.left))\" y1=\"\(round2(gridY))\""
                + " x2=\"\(round2(graphWidth - inset.right))\" y2=\"\(round2(gridY))\"/>"
            svg += "<text class=\"axis price\" x=\"\(round2(inset.left - 8))\" y=\"\(round2(gridY + 4))\">"
                + escape(PriceFormatting.string(
                    amount: Decimal(price), currency: content.displayCurrency))
                + "</text>"
        }
        svg += "<path class=\"area\" d=\"\(area)\"/>"
        svg += "<path class=\"line\" d=\"\(path)\"/>"
        for (index, point) in points.enumerated() {
            svg += "<circle class=\"dot\" cx=\"\(round2(x(index)))\""
                + " cy=\"\(round2(y(prices[index])))\" r=\"2.5\"/>"
            _ = point
        }
        // Date axis: first and last only. Every bucket labelled is unreadable at
        // a year's worth of points, and the span is what the reader needs.
        if let first = points.first, let last = points.last {
            svg += "<text class=\"axis date start\" x=\"\(round2(inset.left))\""
                + " y=\"\(round2(graphHeight - 10))\">\(escape(day(first.date)))</text>"
            svg += "<text class=\"axis date end\" x=\"\(round2(graphWidth - inset.right))\""
                + " y=\"\(round2(graphHeight - 10))\">\(escape(day(last.date)))</text>"
        }
        return svg + "</svg>"
    }

    // MARK: - Small helpers

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func dataURI(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    /// The image type from its magic bytes. Favicons are served with every wrong
    /// `Content-Type` there is, and a `data:` URI whose declared type is wrong
    /// simply does not render.
    static func mimeType(forImageData data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        return "image/png"
    }

    private static func round2(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static let styleSheet = """
    :root {
      color-scheme: light dark;
      --bg: #f6f6f8; --card: #ffffff; --text: #16161a; --muted: #6b6b76;
      --line: #d9d9e0; --accent: #3f6df0; --accent-soft: rgba(63,109,240,0.14);
      --win-bg: rgba(31,150,96,0.12); --win-text: #14663f;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #101013; --card: #1b1b20; --text: #f2f2f5; --muted: #9a9aa6;
        --line: #303038; --accent: #7d9cff; --accent-soft: rgba(125,156,255,0.18);
        --win-bg: rgba(60,200,130,0.16); --win-text: #6fe0a6;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 28px 18px 44px; background: var(--bg); color: var(--text);
      font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      -webkit-text-size-adjust: 100%;
    }
    main { max-width: 680px; margin: 0 auto; }
    .hero {
      display: block; margin: 0 auto 18px; max-width: 220px; max-height: 220px;
      width: auto; height: auto; border-radius: 14px;
    }
    h1 { margin: 0 0 4px; font-size: 23px; line-height: 1.25; text-align: center; }
    h2 {
      margin: 30px 0 10px; font-size: 12px; letter-spacing: 0.08em;
      text-transform: uppercase; color: var(--muted);
    }
    .stamp { margin: 0; text-align: center; color: var(--muted); font-size: 13px; }
    .empty { margin: 0; color: var(--muted); font-size: 14px; }
    .sellers { list-style: none; margin: 0; padding: 0; border-radius: 14px; overflow: hidden; background: var(--card); }
    .seller + .seller { border-top: 1px solid var(--line); }
    .seller a {
      display: flex; align-items: center; gap: 10px; padding: 12px 14px;
      color: inherit; text-decoration: none;
    }
    .seller.lowest { background: var(--win-bg); }
    .icon { width: 22px; height: 22px; border-radius: 5px; flex: 0 0 auto; object-fit: contain; }
    .icon.placeholder { background: var(--accent-soft); }
    .name { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .badge {
      flex: 0 0 auto; font-size: 11px; font-weight: 600; letter-spacing: 0.04em;
      text-transform: uppercase; color: var(--win-text);
    }
    .price { flex: 0 0 auto; font-variant-numeric: tabular-nums; font-weight: 600; }
    .price.none { font-weight: 400; color: var(--muted); }
    .graph { display: block; width: 100%; height: auto; background: var(--card); border-radius: 14px; }
    .graph .grid { stroke: var(--line); stroke-width: 1; }
    .graph .line { fill: none; stroke: var(--accent); stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
    .graph .area { fill: var(--accent-soft); stroke: none; }
    .graph .dot { fill: var(--accent); }
    .graph .axis { fill: var(--muted); font-size: 11px; font-family: inherit; }
    .graph .axis.price { text-anchor: end; }
    .graph .axis.date.start { text-anchor: start; }
    .graph .axis.date.end { text-anchor: end; }
    """
}
