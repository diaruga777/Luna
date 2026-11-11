import Foundation

/// A full-file Google Video request can be throttled even on a fast link.
public enum YouTubeAudioTransfer {
    private static let chunkBytes: Int64 = 8 * 1024 * 1024

    public struct SizeLimit: LocalizedError {
        public var errorDescription: String? { "The audio exceeds your download limit." }
        public init() {}
    }

    public enum Part {
        case complete(URL)
        case next(URLRequest, progress: Double)
    }

    public static func request(for metadata: YouTubeAudioMetadata, allowsCellular: Bool) -> URLRequest {
        var request = URLRequest(url: metadata.downloadURL)
        request.allHTTPHeaderFields = metadata.headers
        request.allowsCellularAccess = allowsCellular
        return bounded(request)
    }

    public static func bounded(_ request: URLRequest) -> URLRequest {
        guard let host = request.url?.host?.lowercased(),
              host == "googlevideo.com" || host.hasSuffix(".googlevideo.com"),
              request.value(forHTTPHeaderField: "Range") == nil else { return request }
        var request = request
        request.setValue("bytes=0-\(chunkBytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    /// Includes bytes from completed ranges in both progress and budget checks.
    public static func progress(response: URLResponse?, request: URLRequest?, written: Int64, expected: Int64,
                                maximumBytes: Int64) throws -> Double? {
        let received: Int64, total: Int64
        if let range = contentRange(response), written <= range.end - range.start + 1 {
            received = range.start + written
            total = range.total
        } else {
            received = written
            total = expected
        }
        let size = max(received, total)
        guard size <= maximumBytes else { throw SizeLimit() }
        if (response as? HTTPURLResponse)?.statusCode == 200,
           let range = request?.value(forHTTPHeaderField: "Range"),
           !range.hasPrefix("bytes=0-") || size > chunkBytes {
            throw YouTubeMediaRejection()
        }
        guard total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    /// The original request belongs to URLSession. The only durable state we
    /// write between requests is the partial audio file.
    public static func receive(_ file: URL, response: URLResponse?, request: URLRequest?,
                               partial: URL, maximumBytes: Int64) throws -> Part {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !["html", "json", "xml"].contains(where: { (http.mimeType ?? "").contains($0) }) else {
            throw YouTubeMediaRejection()
        }
        let bytes = try size(of: file)
        guard bytes > 0 else { throw YouTubeMediaRejection() }
        guard bytes <= maximumBytes else { throw SizeLimit() }
        guard let request, let rangeHeader = request.value(forHTTPHeaderField: "Range") else {
            guard http.statusCode == 200 else { throw YouTubeMediaRejection() }
            return .complete(file)
        }
        // Some servers ignore the first Range on short responses.
        if http.statusCode == 200, rangeHeader.hasPrefix("bytes=0-"), bytes <= chunkBytes { return .complete(file) }
        guard let range = contentRange(http),
              rangeHeader == "bytes=\(range.start)-\(range.start + chunkBytes - 1)",
              range.end == min(range.total - 1, range.start + chunkBytes - 1),
              bytes == range.end - range.start + 1 else { throw YouTubeMediaRejection() }
        guard range.total <= maximumBytes else { throw SizeLimit() }
        if range.start == 0 {
            if range.end + 1 == range.total { return .complete(file) }
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
            try FileManager.default.moveItem(at: file, to: partial)
        } else {
            guard try size(of: partial) == range.start else { throw YouTubeMediaRejection() }
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            try output.seekToEnd()
            try output.write(contentsOf: Data(contentsOf: file, options: .mappedIfSafe))
            if range.end + 1 == range.total { return .complete(partial) }
        }
        var next = request
        next.setValue("bytes=\(range.end + 1)-\(range.end + chunkBytes)", forHTTPHeaderField: "Range")
        return .next(next, progress: Double(range.end + 1) / Double(range.total))
    }

    private static func size(of url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func contentRange(_ response: URLResponse?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let header = http.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else { return nil }
        let fields = header.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard fields.count == 3, let start = Int64(fields[0]), let end = Int64(fields[1]), let total = Int64(fields[2]),
              start >= 0, start <= end, end < total, total <= Int64.max - chunkBytes else { return nil }
        return (start, end, total)
    }
}
