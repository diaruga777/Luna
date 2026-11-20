//
//  LinkImportPreviewLoader.swift
//  Luna
//

import LunaDesignSystem
import LunaFetch
import LunaStorage
import UIKit

/// Where a row's preview comes from: the page read, the cover-image download, and
/// whether there is a network to do either over.
protocol LinkImportPreviewNetworking {
    func fetchPreview(for url: URL) async throws -> LinkPreview
    func fetchImageData(from url: URL) async throws -> Data
    var isOnline: Bool { get }
}

/// The shipped answers: the shared preview fetcher, a plain download, and the
/// reachability monitor.
struct LiveLinkImportPreviewNetwork: LinkImportPreviewNetworking {
    static let maximumImageBytes = 4 * 1024 * 1024

    func fetchPreview(for url: URL) async throws -> LinkPreview {
        try await LinkPreviewFetcher().fetchPreview(for: url)
    }

    func fetchImageData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard response.expectedContentLength <= Int64(Self.maximumImageBytes) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var buffer = [UInt8]()
        buffer.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard buffer.count < Self.maximumImageBytes else { throw URLError(.dataLengthExceedsMaximum) }
            buffer.append(byte)
        }
        return Data(buffer)
    }

    var isOnline: Bool { NetworkReachability.shared.isOnline }
}

/// The sheet showing the rows a loader answers for.
@MainActor
protocol LinkImportPreviewLoaderDelegate: AnyObject {
    /// One URL's state changed, so the sheet can refresh just that row instead of
    /// reloading the table under the user's thumb. Always on a LATER turn than the
    /// change itself — see `notifyChange`.
    func previewLoaderDidChangeRow(forURLString urlString: String)
}

/// Fetches titles and thumbnails for the links in the import review list, in
/// a rolling window around what the user can see.
///
/// A file can hold a thousand links, and each preview is a real page read.
/// Fetching the whole file would cost minutes of cellular data for rows the
/// user scrolls past without looking. So a row is fetched when it comes on
/// screen, plus the table's own prefetch lead, and a row that leaves the
/// window before its turn comes around is dropped from the queue rather than
/// fetched. Nothing is speculative: the window is the request list.
///
/// What a row shows while it waits, and if the fetch fails, is the display
/// the sheet always had — the URL's path over its host — so a preview is an
/// upgrade to a row that already works, never a blank waiting to be filled.
@MainActor
final class LinkImportPreviewLoader {

    /// A row's preview, with the thumbnail already decoded to cell size.
    struct Preview: Equatable {
        var title: String?
        var siteName: String?
        var image: UIImage?

        var isEmpty: Bool { title == nil && siteName == nil && image == nil }
    }

    enum State: Equatable {
        /// Not asked for yet (outside the window).
        case idle
        /// In the window, waiting or in flight — the row shows a spinner.
        case loading
        /// Answered. `Preview` may still be empty, meaning the page had nothing
        /// usable to show; the row keeps its URL display either way.
        case loaded(Preview)
        /// Not reachable — no network, or the page didn't answer. No spinner, no
        /// retry: the row stays as it was.
        case unavailable
    }

    /// The sheet showing these rows. Weak — it owns this loader.
    weak var delegate: (any LinkImportPreviewLoaderDelegate)?

    /// How many page reads are in flight at once. Three is enough to keep a
    /// scrolling window filled and small enough that it can't starve the import
    /// itself (which runs on the same connection and matters more).
    private let maximumConcurrent: Int
    /// Thumbnail box, in points. The decode targets this, so a 2000px `og:image`
    /// never becomes a full-size bitmap.
    static let thumbnailSize = CGSize(width: 56, height: 40)

    // MARK: - Seams

    private let network: any LinkImportPreviewNetworking

    init(
        maximumConcurrent: Int = 3,
        network: any LinkImportPreviewNetworking = LiveLinkImportPreviewNetwork()
    ) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.network = network
    }

    // MARK: - State

    /// Answered rows. The value is the preview; a row that was asked and had
    /// nothing to give keeps an empty one, so it is never asked twice.
    private var previews: [String: Preview] = [:]
    private var failed: Set<String> = []
    /// Requested and not yet started, in the order they entered the window.
    private var queue: [String] = []
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Decoded thumbnails, evicted under memory pressure — a fully-scrolled
    /// thousand-link file must not hold a thousand bitmaps. Losing one costs the
    /// row its picture, not a refetch.
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        return cache
    }()

    func state(for urlString: String) -> State {
        if var preview = previews[urlString] {
            preview.image = images.object(forKey: urlString as NSString)
            return .loaded(preview)
        }
        if failed.contains(urlString) { return .unavailable }
        return inFlight[urlString] != nil || queue.contains(urlString) ? .loading : .idle
    }

    // MARK: - The window

    /// Reports a state change one main-actor turn later, never inline.
    ///
    /// `enterWindow` is called from `tableView(_:willDisplay:)`, so the cell must finish
    /// entering the visible rows before the sheet looks it up to update it.
    private func notifyChange(_ urlString: String) {
        guard delegate != nil else { return }
        Task { @MainActor [weak self] in
            self?.delegate?.previewLoaderDidChangeRow(forURLString: urlString)
        }
    }

    /// These rows are on screen (or about to be). Anything not answered yet joins
    /// the queue.
    func enterWindow(_ urlStrings: [String]) {
        for urlString in urlStrings where state(for: urlString) == .idle {
            guard Self.fetchableURL(urlString) != nil else {
                failed.insert(urlString)
                continue
            }
            // Offline is answered here rather than by starting a fetch that will
            // fail: no spinner appears at all, so a row on a plane reads as
            // "this is all there is", not "still loading".
            guard network.isOnline else {
                failed.insert(urlString)
                notifyChange(urlString)
                continue
            }
            queue.append(urlString)
            notifyChange(urlString)
        }
        pump()
    }

    /// These rows have left the window. A queued row is dropped — the data it
    /// would have cost is the point. One already in flight is left to finish and
    /// cache: cancelling it wastes the bytes already spent, and the user scrolling
    /// back is likely.
    func leaveWindow(_ urlStrings: [String]) {
        guard !urlStrings.isEmpty else { return }
        let leaving = Set(urlStrings)
        queue.removeAll { leaving.contains($0) }
    }

    /// The URL to read, or nil when there is nothing worth reading. `URL(string:)`
    /// alone is not that test — modern Foundation happily parses `"not a url"` into
    /// a schemeless relative URL, which `URLSession` then refuses at request time.
    /// So the scheme and host are checked here, before a row is ever spun.
    static func fetchableURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    private func pump() {
        while inFlight.count < maximumConcurrent, !queue.isEmpty {
            let urlString = queue.removeFirst()
            guard let url = Self.fetchableURL(urlString) else {
                failed.insert(urlString)
                notifyChange(urlString)
                continue
            }
            inFlight[urlString] = Task { [weak self] in
                await self?.load(urlString, url: url)
            }
        }
    }

    func stop() {
        queue.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    private func load(_ urlString: String, url: URL) async {
        defer {
            if !Task.isCancelled {
                inFlight[urlString] = nil
                pump()
            }
        }
        guard !Task.isCancelled else { return }
        var preview: LinkPreview?
        do {
            preview = try await network.fetchPreview(for: url)
        } catch {
            preview = nil
        }
        guard !Task.isCancelled else { return }
        guard let preview else {
            failed.insert(urlString)
            notifyChange(urlString)
            return
        }

        // Text first, picture second: the headline is the useful part, and it
        // should appear without waiting on an image download that may not land.
        previews[urlString] = Preview(title: preview.title, siteName: preview.siteName)
        notifyChange(urlString)

        guard let imageURL = preview.imageURL,
              let image = await thumbnail(from: imageURL), !Task.isCancelled else { return }
        images.setObject(image, forKey: urlString as NSString)
        notifyChange(urlString)
    }

    private func thumbnail(from url: URL) async -> UIImage? {
        guard let data = try? await network.fetchImageData(from: url),
              data.count <= LiveLinkImportPreviewNetwork.maximumImageBytes
        else { return nil }
        let scale = UIScreen.main.scale
        let maxPixel = max(Self.thumbnailSize.width, Self.thumbnailSize.height) * scale
        // Decode off the main actor: it is the expensive half of showing an image.
        return await Task.detached(priority: .utility) {
            ImageDownsampling.decode(data: data, scale: scale, maxPixelSize: maxPixel)
        }.value
    }
}
