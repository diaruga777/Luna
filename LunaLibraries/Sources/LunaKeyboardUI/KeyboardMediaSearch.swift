import Foundation

enum KeyboardMediaSearch {
  struct Result: Codable {
    let title: String
    let url: URL
    let thumbnail: URL?
  }
  static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.httpAdditionalHeaders = ["User-Agent": "LunaKeyboard/1.0 (media search)"]
    config.httpMaximumConnectionsPerHost = 3
    config.timeoutIntervalForRequest = 15
    return URLSession(configuration: config)
  }()
  static func search(_ query: String) async throws -> [Result] {
    var components = URLComponents(string: "https://api.giphy.com/v1/gifs/search")!
    components.queryItems = [
      .init(name: "q", value: String(query.prefix(128))), .init(name: "limit", value: "24"),
      .init(name: "api_key", value: KeyboardServiceConfiguration.giphyKey),
      .init(name: "rating", value: "pg-13"),
    ]
    let (data, response) = try await limitedData(from: components.url!)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    return try results(from: data)
  }

  static func results(from data: Data) throws -> [Result] {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return (object["data"] as? [[String: Any]] ?? []).compactMap { value in
      guard let images = value["images"] as? [String: [String: Any]],
        let text = images["fixed_height"]?["url"] as? String, let url = URL(string: text), url.scheme == "https" else { return nil }
      // Small animated renditions preserve Clack's animated storefront without
      // downloading the full copy rendition for every visible cell.
      return Result(title: value["title"] as? String ?? "GIF", url: url,
        thumbnail: (images["fixed_width_small"]?["url"] as? String).flatMap(URL.init(string:)))
    }
  }

  static func limitedData(from url: URL) async throws -> (Data, URLResponse) {
    let (bytes, response) = try await session.bytes(from: url)
    guard response.expectedContentLength <= 2 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < 2 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
      data.append(byte)
    }
    return (data, response)
  }
  static func download(_ url: URL, maxBytes: Int) async throws -> URL {
    guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
    let (local, response) = try await session.download(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      (try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= maxBytes
    else {
      try? FileManager.default.removeItem(at: local)
      throw URLError(.dataLengthExceedsMaximum)
    }
    return local
  }
}
