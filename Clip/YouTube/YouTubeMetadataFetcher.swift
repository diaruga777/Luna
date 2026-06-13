//
//  YouTubeMetadataFetcher.swift
//  Clip
//

import Foundation

/// Title/channel/thumbnail for a YouTube video, fetched without any API key
/// (oEmbed endpoint + the public thumbnail CDN).
protocol YouTubeMetadataFetching {
    /// Title and channel name for a video.
    func fetchMetadata(videoID: String) async throws -> (title: String, channelName: String?)
    /// JPEG thumbnail bytes for a video.
    func fetchThumbnail(videoID: String) async throws -> Data
}

/// Live implementation against youtube.com.
struct YouTubeOEmbedFetcher: YouTubeMetadataFetching {

    struct FetchError: Error {}

    private struct OEmbedResponse: Decodable {
        let title: String
        let authorName: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
        }
    }

    func fetchMetadata(videoID: String) async throws -> (title: String, channelName: String?) {
        let watchURL = YouTubeURL.watchURLString(videoID: videoID)
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: watchURL),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { throw FetchError() }

        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw FetchError() }
        let oembed = try JSONDecoder().decode(OEmbedResponse.self, from: data)
        return (oembed.title, oembed.authorName)
    }

    func fetchThumbnail(videoID: String) async throws -> Data {
        guard let url = YouTubeURL.thumbnailURL(videoID: videoID) else { throw FetchError() }
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 512
        else { throw FetchError() }
        return data
    }
}
