//
//  FaviconFetcher.swift
//  Luna
//
//  Fetches a site's icon (the one browsers show in tabs) for the mini-card
//  scrub chips: the well-known apple-touch-icon first (large, pretty), then
//  whatever the homepage's <head> declares, then the classic /favicon.ico.
//  Every response is validated as a decodable raster image before it wins —
//  many sites 404 with an HTML body at the well-known paths.
//
//  Networking + candidate ranking only; decoding to UIImage and caching are
//  the caller's job (see the app's SourceIconCache).
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftSoup

public struct FaviconFetcher {

    /// Icons larger than this are mis-served files, not favicons.
    public static let maxIconBytes = 2 * 1024 * 1024
    /// Below this pixel size a favicon renders as mush even in a 16pt badge.
    public static let minimumPixelSize = 16

    public init() {}

    /// Raw image bytes for the best available icon of the site hosting
    /// `pageURL`, or nil when nothing usable is found. Never throws — icon
    /// loading is decorative and failures just mean a fallback badge.
    public func fetchIconData(forPageURL pageURL: URL) async -> Data? {
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = pageURL.host, !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        guard let origin = components.url else { return nil }

        // 1. The high-resolution touch icon at its well-known path.
        if let data = await validatedIconData(at: origin.appendingPathComponent("apple-touch-icon.png")) {
            return data
        }
        // 2. Icons the homepage's <head> declares, best-first.
        if let html = try? await ArticleFetcher().fetchHTML(from: origin) {
            for candidate in Self.iconLinkCandidates(inHTML: html, pageURL: origin).prefix(3) {
                if let data = await validatedIconData(at: candidate) { return data }
            }
        }
        // 3. The classic fallback.
        return await validatedIconData(at: origin.appendingPathComponent("favicon.ico"))
    }

    /// Icon URLs declared by `<link rel*=icon>` in `html`, best-first:
    /// apple-touch icons beat plain favicons, then larger declared `sizes`
    /// win. SVG entries are dropped (ImageIO can't decode them); relative
    /// hrefs resolve against `pageURL`. Pure (no I/O) so ranking is testable.
    public static func iconLinkCandidates(inHTML html: String, pageURL: URL) -> [URL] {
        guard let document = try? SwiftSoup.parse(html),
              let links = try? document.select("link[rel~=(?i)icon][href]")
        else { return [] }
        var scored: [(url: URL, score: Int)] = []
        var seen = Set<URL>()
        for link in links.array() {
            let rel = ((try? link.attr("rel")) ?? "").lowercased()
            // mask-icon is a monochrome SVG template, never a raster favicon.
            guard !rel.contains("mask-icon") else { continue }
            let href = ((try? link.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !href.lowercased().hasPrefix("data:"),
                  let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  seen.insert(url).inserted
            else { continue }
            let type = ((try? link.attr("type")) ?? "").lowercased()
            guard !type.contains("svg"), !url.path.lowercased().hasSuffix(".svg") else { continue }
            let declaredSize = ((try? link.attr("sizes")) ?? "")
                .lowercased()
                .split(whereSeparator: { $0 == " " })
                .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
                .max() ?? 0
            let score = (rel.contains("apple-touch-icon") ? 1000 : 0) + min(declaredSize, 512)
            scored.append((url, score))
        }
        return scored.sorted { $0.score > $1.score }.map(\.url)
    }

    /// GETs `url` and returns the bytes only if they decode as a raster image
    /// of a usable size — the well-known icon paths routinely 404 with an
    /// HTML body, and a 200 that isn't an image must not win.
    private func validatedIconData(at url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= Self.maxIconBytes,
              Self.isDecodableIcon(data)
        else { return nil }
        return data
    }

    /// Whether `data` decodes as a raster image at least `minimumPixelSize`
    /// on its longest side (multi-size .ico files pass if ANY frame does).
    public static func isDecodableIcon(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return false }
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any] else { continue }
            let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
            if max(width, height) >= minimumPixelSize { return true }
        }
        return false
    }
}
