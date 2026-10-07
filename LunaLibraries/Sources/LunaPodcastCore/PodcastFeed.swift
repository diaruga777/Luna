import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct PodcastFeed: Sendable {
    public var show: PodcastShow
    public var episodes: [PodcastEpisode]
    public init(show: PodcastShow, episodes: [PodcastEpisode]) { self.show = show; self.episodes = episodes }
    public static func parse(_ data: Data, url: URL, showID: String? = nil) throws -> PodcastFeed {
        guard data.count <= 20 * 1_024 * 1_024 else { throw PodcastError("This podcast feed is too large to load.") }
        let delegate = FeedParser(url: url, id: showID)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.hasFeed else { throw PodcastError("The address did not return a valid podcast RSS or Atom feed.") }
        guard !delegate.show.title.isEmpty else { throw PodcastError("The podcast feed has no title.") }
        return PodcastFeed(show: delegate.show, episodes: delegate.episodes)
    }
}

private final class FeedParser: NSObject, XMLParserDelegate {
    var show: PodcastShow
    var episodes: [PodcastEpisode] = []
    var hasFeed = false
    private var stack: [(String, String)] = []
    private var item: [String: String]?
    private var enclosure: URL?
    private var mediaType = "audio/mpeg"
    private var byteCount: Int64 = 0
    private var image: URL?
    private var link: URL?
    private var chapters: [PodcastChapter] = []
    private var chapterURL: URL?
    private var transcripts: [PodcastTranscriptReference] = []
    private var seen = Set<String>()
    init(url: URL, id: String?) { show = PodcastShow(feedURL: url, title: "", id: id) }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = name.lowercased()
        stack.append((name, ""))
        if name == "rss" || name == "feed" { hasFeed = true }
        if name == "item" || name == "entry" {
            item = [:]; enclosure = nil; image = nil; link = nil; chapters = []; chapterURL = nil; transcripts = []
            mediaType = "audio/mpeg"; byteCount = 0
        }
        if item != nil {
            if name == "enclosure" || (name == "link" && attributes["rel"] == "enclosure") || name == "media:content" {
                let type = attributes["type"] ?? "audio/mpeg"
                if enclosure == nil, type.hasPrefix("audio/") || type.hasPrefix("video/") || type.contains("mpegurl") {
                    enclosure = PodcastIdentity.webURL(attributes["url"] ?? attributes["href"], relativeTo: show.feedURL)
                    mediaType = type; byteCount = Int64(attributes["length"] ?? attributes["fileSize"] ?? "0") ?? 0
                }
            }
            if name == "itunes:image" || name == "media:thumbnail" { image = PodcastIdentity.webURL(attributes["href"] ?? attributes["url"], relativeTo: show.feedURL) }
            if name == "link", attributes["rel"] == "alternate" { link = PodcastIdentity.webURL(attributes["href"], relativeTo: show.feedURL) }
            if name == "podcast:transcript", let url = PodcastIdentity.webURL(attributes["url"], relativeTo: show.feedURL) {
                transcripts.append(.init(url: url, type: attributes["type"] ?? "text/plain", language: attributes["language"]))
            }
            if name == "podcast:chapters" { chapterURL = PodcastIdentity.webURL(attributes["url"], relativeTo: show.feedURL) }
            if name == "psc:chapter", let start = PodcastTime.seconds(attributes["start"] ?? "") {
                chapters.append(.init(start: start, title: attributes["title"] ?? "Chapter", url: PodcastIdentity.webURL(attributes["href"]), imageURL: PodcastIdentity.webURL(attributes["image"])))
            }
        } else {
            if name == "itunes:image" { show.artworkURL = PodcastIdentity.webURL(attributes["href"], relativeTo: show.feedURL) }
            if name == "itunes:category", let category = attributes["text"], !show.categories.contains(category) { show.categories.append(category) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !stack.isEmpty { stack[stack.count - 1].1 += string } }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let element = stack.popLast() else { return }
        let name = element.0, text = element.1.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stack.isEmpty { stack[stack.count - 1].1 += element.1 }
        if name == "item" || name == "entry" { finishItem(); item = nil; return }
        if item != nil {
            if stack.last?.0 == "item" || stack.last?.0 == "entry" { item?[name] = text }
        } else {
            let parent = stack.last?.0
            if parent == "channel" || parent == "feed" {
                switch name {
                case "title": show.title = text
                case "itunes:author", "author", "managingeditor": if show.author.isEmpty { show.author = text }
                case "description", "subtitle", "itunes:summary": if show.summary.isEmpty { show.summary = text }
                case "link": show.websiteURL = PodcastIdentity.webURL(text, relativeTo: show.feedURL)
                case "itunes:explicit": show.explicit = ["yes", "true", "explicit"].contains(text.lowercased())
                case "itunes:type": show.serial = text.lowercased() == "serial"
                case "category": if !text.isEmpty && !show.categories.contains(text) { show.categories.append(text) }
                default: break
                }
            }
            if name == "url", parent == "image", show.artworkURL == nil { show.artworkURL = PodcastIdentity.webURL(text, relativeTo: show.feedURL) }
        }
    }
    private func finishItem() {
        guard let item, let enclosure else { return }
        let guid = [item["guid"], item["id"], enclosure.absoluteString].compactMap { $0 }.first { !$0.isEmpty }!
        let id = PodcastIdentity.episode(showID: show.id, guid: guid)
        guard seen.insert(id).inserted else { return }
        var episode = PodcastEpisode(showID: show.id, guid: guid, title: item["title"] ?? "Untitled Episode",
                                     publishedAt: PodcastTime.date(item["pubdate"] ?? item["published"] ?? item["updated"] ?? "") ?? .distantPast, mediaURL: enclosure)
        episode.summary = item["content:encoded"] ?? item["description"] ?? item["itunes:summary"] ?? item["content"] ?? item["summary"] ?? ""
        episode.duration = PodcastTime.seconds(item["itunes:duration"] ?? "") ?? 0
        episode.mediaType = mediaType; episode.byteCount = byteCount
        episode.artworkURL = image ?? show.artworkURL; episode.websiteURL = link ?? PodcastIdentity.webURL(item["link"], relativeTo: show.feedURL)
        episode.season = item["itunes:season"].flatMap(Int.init); episode.number = item["itunes:episode"].flatMap(Int.init)
        episode.episodeType = item["itunes:episodetype"] ?? "full"
        episode.explicit = ["yes", "true", "explicit"].contains((item["itunes:explicit"] ?? "").lowercased())
        episode.chapters = chapters; episode.chaptersURL = chapterURL; episode.transcripts = transcripts
        episodes.append(episode)
    }
}
public enum PodcastTime {
    public static func seconds(_ string: String) -> Double? {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var result: Double = 0
        for part in parts { guard let value = Double(part), value.isFinite, value >= 0 else { return nil }; result = result * 60 + value }
        return result
    }
    public static func date(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: string) { return date }
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
