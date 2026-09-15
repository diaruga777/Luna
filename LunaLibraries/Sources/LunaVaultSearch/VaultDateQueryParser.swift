import Foundation

/// The date grammar used by Vault's search box. Dates intentionally refer to
/// BEP's one portable timestamp: modification time. Creation dates from file
/// formats are not guessed or mixed into query semantics.
public struct VaultDateQuery: Equatable, Sendable {
    public var text: String
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?

    public init(text: String, modifiedAfter: Date? = nil, modifiedBefore: Date? = nil) {
        self.text = text; self.modifiedAfter = modifiedAfter; self.modifiedBefore = modifiedBefore
    }
}

public enum VaultDateQueryParser {
    public static func parse(_ query: String, calendar suppliedCalendar: Calendar? = nil) -> VaultDateQuery {
        let calendar = suppliedCalendar ?? utcCalendar
        let pattern = #"(?i)(after|before|modified-after|modified-before):([0-9]{4}-[0-9]{2}-[0-9]{2})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return VaultDateQuery(text: query) }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        var after: Date?
        var before: Date?
        var removals: [Range<String.Index>] = []
        expression.enumerateMatches(in: query, range: range) { match, _, _ in
            guard let match, let whole = Range(match.range, in: query),
                  let operation = Range(match.range(at: 1), in: query),
                  let value = Range(match.range(at: 2), in: query),
                  let date = Self.date(String(query[value]), calendar: calendar) else { return }
            if String(query[operation]).lowercased().contains("after") { after = date }
            else { before = date }
            removals.append(whole)
        }
        var text = query
        for removal in removals.sorted(by: { $0.lowerBound > $1.lowerBound }) { text.removeSubrange(removal) }
        return VaultDateQuery(text: text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "),
                              modifiedAfter: after, modifiedBefore: before)
    }

    private static func date(_ value: String, calendar: Calendar) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2]))
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
    }
}
