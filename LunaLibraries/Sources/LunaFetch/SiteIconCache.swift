//
//  SiteIconCache.swift
//  LunaFetch
//
//  Site icons, for anything in Luna that shows WHERE something came from: the
//  Reader's mini-card scrub chips and the price tracker's seller rows. Wraps
//  `FaviconFetcher` with the layers it deliberately doesn't have: a memory
//  cache, a disk cache (Caches/SourceIcons/<host>.png), a negative cache so
//  hosts with no icon aren't re-probed every reload, and in-flight
//  de-duplication so one reload fetches each host once.
//
//  It lives here rather than in the app shell because the seller rows also draw
//  inside the share and action extensions, which have no app shell to borrow
//  from — and a second copy of this file is how two surfaces start disagreeing
//  about which hosts have icons.
//
//  Main-thread confined: call `icon(forPageURL:completion:)` on main;
//  completions are delivered on main (synchronously on a memory/disk hit).
//

import ImageIO
import UIKit

public final class SiteIconCache {

    public static let shared = SiteIconCache()

    /// Failed hosts aren't re-probed until this much time passes.
    private static let missRetryInterval: TimeInterval = 7 * 24 * 3600
    /// Icons are downscaled to at most this (longest side, points) before
    /// caching — chips render them at ~16pt.
    private static let maxIconSide: CGFloat = 120

    private let memory = NSCache<NSString, UIImage>()
    private var knownMisses = Set<String>()
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]
    private let fetcher = FaviconFetcher()
    private let directory: URL

    private init() {
        directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The icon for the site hosting `pageURL`. The completion fires exactly
    /// once: synchronously on a cache hit, after the network otherwise.
    public func icon(forPageURL pageURL: URL, completion: @escaping (UIImage?) -> Void) {
        guard let host = Self.cacheKey(forPageURL: pageURL) else {
            completion(nil)
            return
        }
        if let cached = memory.object(forKey: host as NSString) {
            completion(cached)
            return
        }
        if knownMisses.contains(host) {
            completion(nil)
            return
        }
        if let image = diskImage(forHost: host) {
            memory.setObject(image, forKey: host as NSString)
            completion(image)
            return
        }
        if isRecentDiskMiss(forHost: host) {
            knownMisses.insert(host)
            completion(nil)
            return
        }
        if inFlight[host] != nil {
            inFlight[host]?.append(completion)
            return
        }
        inFlight[host] = [completion]
        let fetcher = fetcher
        Task {
            let data = await fetcher.fetchIconData(forPageURL: pageURL)
            let image = data.flatMap(Self.decodedIcon(from:))
            await MainActor.run { self.finishFetch(forHost: host, image: image) }
        }
    }

    private func finishFetch(forHost host: String, image: UIImage?) {
        if let image {
            memory.setObject(image, forKey: host as NSString)
            if let png = image.pngData() {
                try? png.write(to: iconFile(forHost: host), options: .atomic)
            }
        } else {
            knownMisses.insert(host)
            FileManager.default.createFile(atPath: missFile(forHost: host).path, contents: nil)
        }
        let waiters = inFlight.removeValue(forKey: host) ?? []
        for waiter in waiters { waiter(image) }
    }

    // MARK: - Keys and files

    /// One icon per site: the lowercased, `www.`-stripped host — reduced to
    /// safe filename characters so a hostile host string can't traverse paths.
    public static func cacheKey(forPageURL url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let safe = host.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return safe.isEmpty ? nil : safe
    }

    private func iconFile(forHost host: String) -> URL {
        directory.appendingPathComponent("\(host).png")
    }

    private func missFile(forHost host: String) -> URL {
        directory.appendingPathComponent("\(host).miss")
    }

    private func diskImage(forHost host: String) -> UIImage? {
        guard let data = try? Data(contentsOf: iconFile(forHost: host)) else { return nil }
        return UIImage(data: data, scale: UIScreen.main.scale)
    }

    private func isRecentDiskMiss(forHost host: String) -> Bool {
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: missFile(forHost: host).path)[.modificationDate] as? Date
        else { return false }
        guard Date().timeIntervalSince(modified) < Self.missRetryInterval else {
            try? FileManager.default.removeItem(at: missFile(forHost: host))
            return false
        }
        return true
    }

    // MARK: - Decoding

    /// Decodes icon bytes, picking the LARGEST frame of a multi-size .ico
    /// (UIImage(data:) takes the first, often the 16px one), then downscales
    /// to the cache ceiling.
    static func decodedIcon(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        var bestIndex = 0
        var bestSide = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any] else { continue }
            let side = max(
                (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0,
                (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0)
            if side > bestSide {
                bestSide = side
                bestIndex = index
            }
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, bestIndex, nil) else { return nil }
        let image = UIImage(cgImage: cgImage)
        let side = max(image.size.width, image.size.height)
        guard side > maxIconSide else { return image }
        let scale = maxIconSide / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
