import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct PodcastTranscriptCue: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}
public enum PodcastTranscript {
    public static func parse(_ data: Data, type: String) throws -> [PodcastTranscriptCue] {
        guard data.count <= 20 * 1_024 * 1_024 else { throw PodcastError("This transcript is too large.") }
        let string = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        if type.contains("json") {
            struct Document: Decodable { struct Segment: Decodable { var startTime: Double; var endTime: Double?; var body: String }; var segments: [Segment] }
            return try JSONDecoder().decode(Document.self, from: data).segments.map { .init(start: $0.startTime, end: $0.endTime ?? $0.startTime, text: $0.body) }
        }
        if type.contains("ttml") || type.contains("xml") {
            let reader = TTMLReader(); let parser = XMLParser(data: data); parser.delegate = reader; parser.shouldResolveExternalEntities = false
            guard parser.parse() else { throw PodcastError("This transcript could not be read.") }
            return reader.cues
        }
        if type.contains("vtt") || type.contains("srt") || type.contains("subrip") || string.hasPrefix("WEBVTT") {
            var cues: [PodcastTranscriptCue] = []
            for block in string.components(separatedBy: "\n\n") {
                let lines = block.components(separatedBy: "\n")
                guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
                let times = lines[index].components(separatedBy: "-->")
                guard times.count == 2, let start = PodcastTime.seconds(times[0]),
                      let end = PodcastTime.seconds(times[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else { continue }
                let body = lines.dropFirst(index + 1).joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if !body.isEmpty { cues.append(.init(start: start, end: end, text: body)) }
            }
            return cues.sorted { $0.start < $1.start }
        }
        return [.init(start: 0, end: 0, text: string)]
    }
}
private final class TTMLReader: NSObject, XMLParserDelegate {
    var cues: [PodcastTranscriptCue] = []
    private var start: Double?; private var end: Double = 0; private var text = ""
    private func time(_ value: String?) -> Double? {
        guard let value else { return nil }
        if value.hasSuffix("ms") { return Double(value.dropLast(2)).map { $0 / 1000 } }
        if value.hasSuffix("s") { return Double(value.dropLast()) }
        return PodcastTime.seconds(value)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if name == "p" { start = time(attributes["begin"]) ?? 0; end = time(attributes["end"]) ?? ((start ?? 0) + (time(attributes["dur"]) ?? 0)); text = "" }
        if name == "br" { text += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if start != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "p", let start { cues.append(.init(start: start, end: end, text: text.trimmingCharacters(in: .whitespacesAndNewlines))); self.start = nil }
    }
}
public enum PodcastOPML {
    public static func export(_ shows: [PodcastShow]) -> Data {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let rows = shows.filter(\.followed).sorted { $0.title < $1.title }.map {
            "<outline type=\"rss\" text=\"\(escape($0.title))\" title=\"\(escape($0.title))\" xmlUrl=\"\(escape($0.feedURL.absoluteString))\"/>"
        }.joined(separator: "\n")
        return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><opml version=\"2.0\"><head><title>Luna Podcasts</title></head><body>\(rows)</body></opml>".utf8)
    }
    public static func urls(_ data: Data) throws -> [URL] {
        guard data.count <= 5 * 1_024 * 1_024 else { throw PodcastError("The OPML file is too large.") }
        let reader = OPMLReader(); let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse() else { throw PodcastError("This is not a valid OPML file.") }
        return reader.urls
    }
}
private final class OPMLReader: NSObject, XMLParserDelegate {
    var urls: [URL] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if name == "outline", let url = PodcastIdentity.webURL(attributes["xmlUrl"] ?? attributes["xmlurl"]), !urls.contains(url) { urls.append(url) }
    }
}
