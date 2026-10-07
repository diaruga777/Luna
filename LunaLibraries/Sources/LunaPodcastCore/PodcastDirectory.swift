import Foundation

public struct PodcastDirectoryResult: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var artworkURL: URL?
    public var feedURL: URL?
    public var episodeURL: URL?
    public var episodeTitle: String?
    public var collectionID: String
}
public struct PodcastDirectory: Sendable {
    public var session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func search(_ term: String, episodes: Bool = false, country: String = "us") async throws -> [PodcastDirectoryResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: episodes ? "podcastEpisode" : "podcast"), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "country", value: country)]
        return try await results(url: components.url!)
    }
    public func lookup(_ ids: [String], country: String = "us") async throws -> [PodcastDirectoryResult] {
        guard !ids.isEmpty else { return [] }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: ids.prefix(100).joined(separator: ",")), URLQueryItem(name: "entity", value: "podcast"), URLQueryItem(name: "country", value: country)]
        let values = try await results(url: components.url!)
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return values.sorted { (order[$0.collectionID] ?? 999) < (order[$1.collectionID] ?? 999) }
    }
    public func charts(country: String = "us", genre: String? = nil) async throws -> [PodcastDirectoryResult] {
        let safeCountry = country.range(of: "^[a-zA-Z]{2}$", options: .regularExpression) != nil ? country.lowercased() : "us"
        let genrePath = genre.flatMap { Int($0) }.map { "/genre=\($0)" } ?? ""
        let url = URL(string: "https://itunes.apple.com/\(safeCountry)/rss/toppodcasts/limit=100\(genrePath)/json")!
        let data = try await data(url)
        struct Chart: Decodable {
            struct Feed: Decodable {
                struct Entry: Decodable {
                    struct ID: Decodable { struct Attributes: Decodable { var id: String; enum CodingKeys: String, CodingKey { case id = "im:id" } }; var attributes: Attributes }
                    var id: ID
                }
                var entry: [Entry]?
            }
            var feed: Feed
        }
        let chart = try JSONDecoder().decode(Chart.self, from: data)
        return try await lookup((chart.feed.entry ?? []).map { $0.id.attributes.id }, country: safeCountry)
    }
    private func results(url: URL) async throws -> [PodcastDirectoryResult] {
        struct Response: Decodable {
            struct Result: Decodable {
                var collectionId: Int64?; var trackId: Int64?; var collectionName: String?; var trackName: String?
                var artistName: String?; var artworkUrl600: String?; var artworkUrl100: String?; var feedUrl: String?
                var episodeUrl: String?; var kind: String?
            }
            var results: [Result]
        }
        return try JSONDecoder().decode(Response.self, from: await data(url)).results.compactMap { result in
            guard let id = result.collectionId ?? result.trackId else { return nil }
            return PodcastDirectoryResult(id: String(result.trackId ?? id), title: result.collectionName ?? result.trackName ?? "Podcast", author: result.artistName ?? "",
                artworkURL: PodcastIdentity.webURL(result.artworkUrl600 ?? result.artworkUrl100), feedURL: PodcastIdentity.webURL(result.feedUrl),
                episodeURL: PodcastIdentity.webURL(result.episodeUrl), episodeTitle: result.kind == "podcast-episode" ? result.trackName : nil, collectionID: String(id))
        }
    }
    private func data(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PodcastError("The podcast directory is unavailable. Please try again.") }
        guard data.count <= 20 * 1_024 * 1_024 else { throw PodcastError("The directory response was too large.") }
        return data
    }
    public static let categories: [(id: String, name: String)] = [
        ("1301", "Arts"), ("1321", "Business"), ("1303", "Comedy"), ("1304", "Education"), ("1483", "Fiction"),
        ("1511", "Government"), ("1512", "Health & Fitness"), ("1487", "History"), ("1305", "Kids & Family"),
        ("1502", "Leisure"), ("1310", "Music"), ("1489", "News"), ("1314", "Religion & Spirituality"),
        ("1533", "Science"), ("1324", "Society & Culture"), ("1545", "Sports"), ("1318", "Technology"),
        ("1488", "True Crime"), ("1309", "TV & Film")]
}

public struct PodcastFeedClient: Sendable {
    public var session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public struct Response: Sendable { public var feed: PodcastFeed?; public var etag: String?; public var lastModified: String? }
    public func fetch(_ show: PodcastShow) async throws -> Response {
        var request = URLRequest(url: show.feedURL)
        request.timeoutInterval = 45; request.setValue("LunaMusic/1.0", forHTTPHeaderField: "User-Agent")
        if let etag = show.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = show.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PodcastError("The podcast feed did not respond.") }
        if http.statusCode == 304 { return Response(feed: nil, etag: show.etag, lastModified: show.lastModified) }
        guard (200..<300).contains(http.statusCode) else { throw PodcastError("The podcast feed returned HTTP \(http.statusCode).") }
        let feed = try PodcastFeed.parse(data, url: response.url ?? show.feedURL, showID: show.id)
        return Response(feed: feed, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }
}
