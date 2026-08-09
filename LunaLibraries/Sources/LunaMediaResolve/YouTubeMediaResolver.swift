//
//  YouTubeMediaResolver.swift
//  Luna
//

import LunaModels
import Foundation
import LunaURLClassification

/// Pure normalization for the common YouTube URL family. Network-only clip
/// expansion is handled separately because `/clip/<id>` doesn't contain its
/// underlying video id or range in the URL.
public struct YouTubeLink: Equatable {
    public let sourceURL: URL
    public let videoID: String?
    public let timeRange: MediaTimeRange?
    public let isClip: Bool

    public init?(url: URL) {
        guard let recognized = PlatformRecognizer.recognize(url.absoluteString),
              recognized.platform == .youtube
        else { return nil }
        sourceURL = url
        videoID = recognized.itemID
        isClip = url.pathComponents.dropFirst().first == "clip"

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        let explicitStart = query.first(where: { $0.name == "start" })?.value
            .flatMap(Self.seconds)
        let sharedStart = query.first(where: { $0.name == "t" })?.value
            .flatMap(Self.seconds)
        let fragmentStart: Double? = {
            guard let fragment = components?.fragment else { return nil }
            let raw = fragment.hasPrefix("t=") ? String(fragment.dropFirst(2)) : fragment
            return Self.seconds(raw)
        }()
        let start = explicitStart ?? sharedStart ?? fragmentStart ?? 0
        let end = query.first(where: { $0.name == "end" })?.value.flatMap(Self.seconds)
        let range = MediaTimeRange(startSeconds: start, endSeconds: end)
        timeRange = range.isEffective ? range : nil
    }

    public var canonicalWatchURL: URL? {
        guard let videoID else { return nil }
        return Self.watchURL(videoID: videoID)
    }

    public var embedURL: URL? {
        videoID.flatMap(Self.embedURL(videoID:))
    }

    public var thumbnailURL: URL? {
        videoID.flatMap(Self.thumbnailURL(videoID:))
    }

    public static func watchURL(videoID: String) -> URL? {
        guard var components = URLComponents(string: "https://www.youtube.com/watch")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    public static func embedURL(videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/embed/\(videoID)?html5=1")
    }

    public static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    /// Accepts plain seconds plus YouTube's `1h2m3s`, `2m10s`, and `90s` forms.
    public static func seconds(_ raw: String) -> Double? {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(value), seconds >= 0 { return seconds }
        let pattern = #"^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m)?(?:(\d+(?:\.\d+)?)s)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value, range: NSRange(value.startIndex..., in: value)),
              match.range.length == value.utf16.count
        else { return nil }
        func component(_ index: Int) -> Double {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: value)
            else { return 0 }
            return Double(value[range]) ?? 0
        }
        let result = component(1) * 3600 + component(2) * 60 + component(3)
        return result > 0 ? result : nil
    }
}

public struct YouTubeClipDescriptor: Equatable {
    public let videoID: String
    public let timeRange: MediaTimeRange
}

public enum YouTubeClipParser {
    public static func descriptor(fromHTML html: String) -> YouTubeClipDescriptor? {
        let search: String
        if let marker = html.range(of: "clipConfig") {
            search = String(html[marker.lowerBound..<html.index(
                marker.lowerBound, offsetBy: min(8_000, html.distance(
                    from: marker.lowerBound, to: html.endIndex)))])
        } else {
            search = html
        }
        let normalized = search.replacingOccurrences(of: #"\""#, with: #"""#)
        guard let videoID = firstGroup(
            in: normalized, pattern: #"\"videoId\"\s*:\s*\"([A-Za-z0-9_-]{11})\""#),
              let startRaw = firstGroup(
                in: normalized, pattern: #"\"startTimeMs\"\s*:\s*\"?(\d+)\"?"#),
              let endRaw = firstGroup(
                in: normalized, pattern: #"\"endTimeMs\"\s*:\s*\"?(\d+)\"?"#),
              let start = Double(startRaw), let end = Double(endRaw), end > start
        else { return nil }
        return YouTubeClipDescriptor(
            videoID: videoID,
            timeRange: MediaTimeRange(
                startSeconds: start / 1_000, endSeconds: end / 1_000))
    }
}

/// Selects the best direct progressive MP4 from YouTube's player response.
/// Adaptive-only video/audio pairs are intentionally excluded: Luna's durable
/// background engine is single-file/resumable, and returning a video-only stream
/// would silently lose sound.
public enum YouTubePlayerResponseParser {
    public static func asset(
        from data: Data,
        videoID: String,
        timeRange: MediaTimeRange?
    ) -> MediaAsset? {
        guard let response = responseObject(from: data) else { return nil }
        return asset(from: response, videoID: videoID, timeRange: timeRange)
    }

    private static func responseObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["streamingData"] != nil {
            return object
        }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        // YouTube commonly emits `var ytInitialPlayerResponse = null` before the
        // real assignment. Walk every occurrence and only accept a value whose
        // first non-whitespace character is `{`; never jump from `null` to an
        // unrelated script object's opening brace.
        var cursor = html.startIndex
        while let name = html[cursor...].range(of: "ytInitialPlayerResponse") {
            defer { cursor = name.upperBound }
            guard let equals = html[name.upperBound...].firstIndex(of: "=") else { continue }
            var valueStart = html.index(after: equals)
            while valueStart < html.endIndex,
                  html[valueStart].isWhitespace {
                valueStart = html.index(after: valueStart)
            }
            guard valueStart < html.endIndex, html[valueStart] == "{",
                  let json = balancedJSONObject(in: html, startingAt: valueStart),
                  let object = try? JSONSerialization.jsonObject(
                    with: Data(json.utf8)) as? [String: Any],
                  object["streamingData"] != nil
            else { continue }
            return object
        }
        return nil
    }

    private static func asset(
        from response: [String: Any],
        videoID: String,
        timeRange: MediaTimeRange?
    ) -> MediaAsset? {
        guard let streaming = response["streamingData"] as? [String: Any],
              let formats = streaming["formats"] as? [[String: Any]]
        else { return nil }
        let duration = ((response["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String)
            .flatMap(Double.init)
        let thumbnail = bestThumbnail(response: response)
            ?? URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")

        let candidates: [(asset: MediaAsset, height: Int, bitrate: Int)] = formats.compactMap { format in
            guard let mime = format["mimeType"] as? String,
                  mime.lowercased().contains("video/mp4"),
                  (format["audioQuality"] != nil || mime.contains(",")),
                  let urlString = format["url"] as? String,
                  let url = URL(string: urlString)
            else { return nil }
            let contentLength = int64(format["contentLength"])
                ?? approximateSize(format: format, duration: duration)
            let asset = MediaAsset(
                url: url,
                kind: .video,
                thumbnailURL: thumbnail,
                estimatedByteCount: contentLength,
                timeRange: timeRange)
            return (
                asset,
                (format["height"] as? NSNumber)?.intValue ?? 0,
                (format["bitrate"] as? NSNumber)?.intValue ?? 0)
        }
        return candidates.max {
            ($0.height, $0.bitrate) < ($1.height, $1.bitrate)
        }?.asset
    }

    private static func bestThumbnail(response: [String: Any]) -> URL? {
        guard let details = response["videoDetails"] as? [String: Any],
              let thumbnail = details["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]]
        else { return nil }
        return thumbnails.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.last
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? String { return Int64(value) }
        return (value as? NSNumber)?.int64Value
    }

    private static func approximateSize(
        format: [String: Any], duration: Double?
    ) -> Int64? {
        guard let duration, duration > 0,
              let bitrate = (format["bitrate"] as? NSNumber)?.doubleValue,
              bitrate > 0
        else { return nil }
        return Int64((bitrate / 8) * duration)
    }

    private static func balancedJSONObject(
        in text: String, startingAt start: String.Index
    ) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

public struct YouTubePlaybackBootstrap: Equatable {
    public let visitorData: String
    public let playerJavaScriptURL: URL
}

/// The normal mobile watch-page response currently advertises an `MWEB`
/// progressive MP4, but YouTube's Google Video servers reject that URL without
/// a GVS Proof-of-Origin token. The maintained yt-dlp fallback for clients
/// without a JS/PO-token provider is an ANDROID_VR player request. That request
/// still needs the guest visitor session established by the watch page and the
/// signature timestamp from its active player JavaScript.
public enum YouTubePlaybackBootstrapParser {
    public static func bootstrap(fromWatchData data: Data) -> YouTubePlaybackBootstrap? {
        guard let html = String(data: data, encoding: .utf8),
              let visitorLiteral = firstGroup(
                in: html,
                pattern: #"\"VISITOR_DATA\"\s*:\s*(\"(?:\\.|[^\"\\])*\")"#),
              let rawVisitor = decodeJSONString(visitorLiteral),
              let playerLiteral = firstGroup(
                in: html,
                pattern: #"\"(?:jsUrl|PLAYER_JS_URL)\"\s*:\s*(\"(?:\\.|[^\"\\])*\")"#),
              let playerPath = decodeJSONString(playerLiteral),
              let playerURL = URL(string: playerPath, relativeTo: URL(
                string: "https://www.youtube.com")!)?.absoluteURL
        else { return nil }
        return YouTubePlaybackBootstrap(
            visitorData: rawVisitor.removingPercentEncoding ?? rawVisitor,
            playerJavaScriptURL: playerURL)
    }

    public static func signatureTimestamp(fromPlayerJavaScript data: Data) -> Int? {
        guard let source = String(data: data, encoding: .utf8),
              let raw = firstGroup(
                in: source,
                pattern: #"(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})"#)
        else { return nil }
        return Int(raw)
    }

    private static func decodeJSONString(_ literal: String) -> String? {
        guard let data = literal.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) as? String
        else { return nil }
        return value
    }
}

public struct YouTubeMediaResolver {
    public typealias Fetch = SocialMediaResolver.Fetch
    public let fetch: Fetch

    /// yt-dlp's current no-token player fallback. Versions newer than 1.65 can
    /// return SABR-only responses, so keep this exact client/version pairing.
    static let androidVRClientVersion = "1.65.10"
    public static let androidVRUserAgent =
        "com.google.android.apps.youtube.vr.oculus/1.65.10 " +
        "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
    public static let webSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"

    public init(fetch: @escaping Fetch = SocialMediaResolver.defaultFetch) {
        self.fetch = fetch
    }

    public func resolveAssets(for sourceURL: URL) async -> [MediaAsset] {
        guard let link = YouTubeLink(url: sourceURL) else { return [] }
        var videoID = link.videoID
        var range = link.timeRange

        if link.isClip {
            guard let data = await fetch(Self.htmlRequest(sourceURL)),
                  let html = String(data: data, encoding: .utf8),
                  let clip = YouTubeClipParser.descriptor(fromHTML: html)
            else { return [] }
            videoID = clip.videoID
            range = clip.timeRange
        }
        guard let videoID else { return [] }

        guard let watchURL = YouTubeLink.watchURL(videoID: videoID) else { return [] }
        let watchData = await fetch(Self.watchRequest(watchURL))

        // The live path: establish a guest session from the watch page, read the
        // active player's signature timestamp, then ask the no-token Android VR
        // client for direct HTTPS formats. Keep all requests in the injected
        // fetcher's URLSession so its cookie store binds the guest session.
        if let watchData,
           let bootstrap = YouTubePlaybackBootstrapParser.bootstrap(
            fromWatchData: watchData),
           let playerJavaScript = await fetch(
            Self.playerJavaScriptRequest(bootstrap.playerJavaScriptURL)),
           let signatureTimestamp =
            YouTubePlaybackBootstrapParser.signatureTimestamp(
                fromPlayerJavaScript: playerJavaScript),
           let playerData = await fetch(Self.androidVRPlayerRequest(
            videoID: videoID,
            visitorData: bootstrap.visitorData,
            signatureTimestamp: signatureTimestamp)),
           let asset = YouTubePlayerResponseParser.asset(
            from: playerData, videoID: videoID, timeRange: range) {
            return [asset]
        }

        // Fixture/legacy fallback. Real MWEB Google Video URLs increasingly 403,
        // so this is deliberately reached only after the working player-client
        // handshake above has been attempted.
        if let watchData,
           let asset = YouTubePlayerResponseParser.asset(
            from: watchData, videoID: videoID, timeRange: range) {
            return [asset]
        }

        if let embedURL = URL(string: "https://www.youtube.com/embed/\(videoID)?html5=1"),
           let data = await fetch(Self.htmlRequest(embedURL)),
           let asset = YouTubePlayerResponseParser.asset(
            from: data, videoID: videoID, timeRange: range) {
            return [asset]
        }

        // Final keyless attempt: use the public Innertube configuration exposed
        // by the watch page with the embedded-player client. Responses that only
        // contain ciphered/PO-token formats remain unsupported and fail clearly.
        guard let watchData,
              let request = Self.playerRequest(
                fromWatchData: watchData, videoID: videoID)
        else { return [] }
        guard let data = await fetch(request),
              let asset = YouTubePlayerResponseParser.asset(
                from: data, videoID: videoID, timeRange: range)
        else { return [] }
        return [asset]
    }

    public static func watchRequest(_ url: URL) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query = components?.queryItems ?? []
        if !query.contains(where: { $0.name == "bpctr" }) {
            query.append(URLQueryItem(name: "bpctr", value: "9999999999"))
        }
        if !query.contains(where: { $0.name == "has_verified" }) {
            query.append(URLQueryItem(name: "has_verified", value: "1"))
        }
        components?.queryItems = query
        return htmlRequest(components?.url ?? url)
    }

    public static func htmlRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpShouldHandleCookies = true
        request.setValue(webSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue("en-us,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        // Avoid the consent interstitial while still allowing URLSession to
        // retain the guest VISITOR/YSC cookies returned by this request.
        request.setValue("PREF=hl=en&tz=UTC; SOCS=CAI", forHTTPHeaderField: "Cookie")
        return request
    }

    public static func playerJavaScriptRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpShouldHandleCookies = true
        request.setValue(webSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        return request
    }

    public static func androidVRPlayerRequest(
        videoID: String,
        visitorData: String,
        signatureTimestamp: Int
    ) -> URLRequest {
        let endpoint = URL(
            string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(androidVRUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("28", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(
            androidVRClientVersion,
            forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context": ["client": [
                "clientName": "ANDROID_VR",
                "clientVersion": androidVRClientVersion,
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "userAgent": androidVRUserAgent,
                "osName": "Android",
                "osVersion": "12L",
                "hl": "en",
                "timeZone": "UTC",
                "utcOffsetMinutes": 0,
            ]],
            "videoId": videoID,
            "playbackContext": ["contentPlaybackContext": [
                "html5Preference": "HTML5_PREF_WANTS",
                "signatureTimestamp": signatureTimestamp,
            ]],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ])
        return request
    }

    public static func playerRequest(fromWatchData data: Data, videoID: String) -> URLRequest? {
        guard let html = String(data: data, encoding: .utf8),
              let apiKey = firstGroup(
                in: html, pattern: #"\"INNERTUBE_API_KEY\"\s*:\s*\"([^\"]+)\""#)
        else { return nil }
        guard let version = firstGroup(
            in: html,
            pattern: #"\"INNERTUBE_CLIENT_VERSION\"\s*:\s*\"([^\"]+)\""#)
        else { return nil }
        var endpoint = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")
        endpoint?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let endpointURL = endpoint?.url else { return nil }
        var request = URLRequest(url: endpointURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": ["client": [
                "clientName": "WEB_EMBEDDED_PLAYER",
                "clientVersion": version,
                "hl": "en",
                "gl": "US",
            ]],
        ])
        return request.httpBody == nil ? nil : request
    }
}

private func firstGroup(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(
        pattern: pattern, options: [.dotMatchesLineSeparators]),
          let match = regex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}
