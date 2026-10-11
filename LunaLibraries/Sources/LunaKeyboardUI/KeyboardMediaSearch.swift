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
    config.httpMaximumConnectionsPerHost = 3
    config.timeoutIntervalForRequest = 15
    return URLSession(configuration: config)
  }()
  static func search(_ query: String, gifs: Bool) async throws -> [Result] {
    var components = URLComponents(
      string: gifs
        ? "https://api.giphy.com/v1/gifs/search" : "https://api.qwant.com/v3/search/images")!
    components.queryItems = [
      .init(name: "q", value: query), .init(name: gifs ? "limit" : "count", value: "24"),
    ]
    if gifs {
      components.queryItems?.append(
        .init(name: "api_key", value: KeyboardServiceConfiguration.giphyKey))
      components.queryItems?.append(.init(name: "rating", value: "pg-13"))
    } else {
      components.queryItems?.append(.init(name: "t", value: "images"))
      components.queryItems?.append(.init(name: "locale", value: "en_us"))
      components.queryItems?.append(.init(name: "offset", value: "0"))
    }
    let (data, response) = try await limitedData(from: components.url!)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.count < 2 * 1024 * 1024
    else {
      if !gifs { return try await openverse(query) }
      throw URLError(.badServerResponse)
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    if gifs {
      return (object["data"] as? [[String: Any]] ?? []).compactMap { value in
        guard let images = value["images"] as? [String: [String: Any]],
          let original = images["fixed_height"], let text = original["url"] as? String,
          let url = URL(string: text)
        else { return nil }
        return Result(
          title: value["title"] as? String ?? "GIF", url: url,
          thumbnail: (images["fixed_width_downsampled"]?["url"] as? String).flatMap(URL.init(string:)))
      }
    }
    let dataObject = object["data"] as? [String: Any]
    let result = dataObject?["result"] as? [String: Any]
    return (result?["items"] as? [[String: Any]] ?? []).compactMap { value in
      guard let text = value["media"] as? String, let url = URL(string: text), url.scheme == "https"
      else { return nil }
      return Result(
        title: value["title"] as? String ?? "Image", url: url,
        thumbnail: (value["thumbnail"] as? String).flatMap(URL.init(string:)))
    }
  }
  // The legacy Qwant API may reject anonymous requests. Keep image search
  // usable with a public-domain/CC0 Openverse fallback when that happens.
  static func openverse(_ query: String) async throws -> [Result] {
    var url = URLComponents(string: "https://api.openverse.org/v1/images/")!
    url.queryItems = [
      .init(name: "q", value: query), .init(name: "page_size", value: "24"),
      .init(name: "license", value: "cc0,pdm"),
    ]
    let (data, response) = try await limitedData(from: url.url!)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.count < 2 * 1024 * 1024
    else { throw URLError(.badServerResponse) }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return (object["results"] as? [[String: Any]] ?? []).compactMap { value in
      guard let path = value["url"] as? String, let url = URL(string: path), url.scheme == "https"
      else { return nil }
      return Result(
        title: value["title"] as? String ?? "Image", url: url,
        thumbnail: (value["thumbnail"] as? String).flatMap(URL.init(string:)))
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
