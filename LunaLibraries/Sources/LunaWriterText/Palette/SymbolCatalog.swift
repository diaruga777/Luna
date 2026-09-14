import Foundation

/// One character the palette's "symbol" command can insert.
public struct UnicodeSymbol: Equatable, Sendable {
    public let character: String
    /// Title-cased from the Unicode name, e.g. "Em Dash".
    public let name: String
    /// Extra words a writer may type for it, e.g. "emdash", "--".
    public let aliases: [String]

    public init(character: String, name: String, aliases: [String] = []) {
        self.character = character
        self.name = name
        self.aliases = aliases
    }

    var searchStrings: [String] { [name] + aliases }
}

/// The symbols the "symbol" command searches: punctuation, Greek, arrows,
/// mathematics, currency, typographic and technical marks. Built once from
/// the Unicode names of fixed code-point ranges plus a hand-written alias
/// table for the names writers actually use.
public final class SymbolCatalog {

    public static let shared = SymbolCatalog()

    public let symbols: [UnicodeSymbol]

    public init() {
        symbols = Self.build()
    }

    /// The best `limit` matches for `query`, aliases counting the same as
    /// the name.
    public func search(_ query: String, limit: Int = 8) -> [UnicodeSymbol] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return FuzzyMatcher.rank(symbols, query: query, limit: limit) { $0.searchStrings }
            .map(\.item)
    }

    // MARK: - Building

    private static let ranges: [ClosedRange<UInt32>] = [
        0x00A1...0x00AC, 0x00AE...0x00BF, 0x00D7...0x00D7, 0x00F7...0x00F7,
        0x0391...0x03A1, 0x03A3...0x03A9, 0x03B1...0x03C9,
        0x2010...0x2027, 0x2030...0x203B, 0x2044...0x2044, 0x2047...0x204A,
        0x2070...0x2071, 0x2074...0x208E, 0x2090...0x209C,
        0x20A0...0x20C0,
        0x2100...0x214F, 0x2150...0x2189,
        0x2190...0x21FF, 0x2200...0x22FF,
        0x2302...0x2303, 0x2318...0x2318, 0x2325...0x2326, 0x232B...0x232B, 0x238B...0x238B,
        0x23CE...0x23CF, 0x23E9...0x23EF, 0x2400...0x2426,
        0x25A0...0x25FF,
        0x2600...0x2604, 0x260E...0x2612, 0x2614...0x2615, 0x2618...0x2618, 0x2620...0x2622,
        0x262E...0x262F, 0x2639...0x263C, 0x2640...0x2642, 0x2660...0x2667, 0x2669...0x266F,
        0x2680...0x2685, 0x2690...0x269C, 0x26A0...0x26A1,
        0x2713...0x271D, 0x2720...0x2721, 0x2733...0x2734, 0x2744...0x2747, 0x274C...0x274C,
        0x2764...0x2767, 0x2794...0x2794, 0x2798...0x27A4, 0x27A5...0x27BE,
    ]

    /// Names writers type that the Unicode name does not carry.
    private static let aliases: [UInt32: [String]] = [
        0x2014: ["emdash", "em-dash", "long dash", "--", "---"],
        0x2013: ["endash", "en-dash", "range dash"],
        0x2012: ["figure dash"],
        0x2015: ["quotation dash"],
        0x2026: ["ellipsis", "dots", "..."],
        0x2022: ["bullet", "dot"],
        0x00B7: ["middle dot", "interpunct"],
        0x00A9: ["copyright", "(c)"],
        0x00AE: ["registered", "(r)"],
        0x2122: ["trademark", "tm"],
        0x2120: ["service mark"],
        0x00B0: ["degree", "degrees"],
        0x00A7: ["section sign"],
        0x00B6: ["paragraph", "pilcrow"],
        0x2020: ["dagger"],
        0x2021: ["double dagger"],
        0x00D7: ["times", "multiply", "x"],
        0x00F7: ["divide", "division"],
        0x00B1: ["plus minus", "plus or minus"],
        0x221E: ["infinity"],
        0x2260: ["not equal", "!="],
        0x2248: ["approximately", "approx", "~="],
        0x2264: ["less than or equal", "<="],
        0x2265: ["greater than or equal", ">="],
        0x221A: ["square root", "sqrt", "root"],
        0x2211: ["sum", "summation"],
        0x220F: ["product"],
        0x222B: ["integral"],
        0x2202: ["partial", "partial derivative"],
        0x2207: ["nabla", "del", "gradient"],
        0x2190: ["left arrow", "<-"],
        0x2192: ["right arrow", "->"],
        0x2191: ["up arrow"],
        0x2193: ["down arrow"],
        0x2194: ["left right arrow", "<->"],
        0x21D2: ["implies", "=>"],
        0x21D4: ["if and only if", "iff", "<=>"],
        0x2018: ["left single quote", "open single quote"],
        0x2019: ["right single quote", "apostrophe", "close single quote"],
        0x201C: ["left double quote", "open quote", "curly quote"],
        0x201D: ["right double quote", "close quote", "curly quote"],
        0x201A: ["low single quote"],
        0x201E: ["low double quote"],
        0x00AB: ["left guillemet", "double angle quote"],
        0x00BB: ["right guillemet", "double angle quote"],
        0x2039: ["left single guillemet"],
        0x203A: ["right single guillemet"],
        0x2032: ["prime", "minutes", "feet"],
        0x2033: ["double prime", "seconds", "inches"],
        0x00A0: ["non-breaking space", "nbsp"],
        0x20AC: ["euro"],
        0x00A3: ["pound", "sterling"],
        0x00A5: ["yen"],
        0x00A2: ["cent"],
        0x20B9: ["rupee"],
        0x20BD: ["ruble", "rouble"],
        0x20A9: ["won"],
        0x20BF: ["bitcoin"],
        0x00B5: ["micro", "mu"],
        0x03C0: ["pi"],
        0x03B5: ["epsilon"],
        0x03BB: ["lambda"],
        0x03B1: ["alpha"],
        0x03B2: ["beta"],
        0x03B3: ["gamma"],
        0x03B4: ["delta"],
        0x03B8: ["theta"],
        0x03C3: ["sigma"],
        0x03C9: ["omega"],
        0x03A9: ["ohm", "capital omega"],
        0x0394: ["capital delta", "change"],
        0x03A3: ["capital sigma"],
        0x2713: ["check", "tick", "checkmark"],
        0x2714: ["heavy check", "heavy tick"],
        0x2717: ["cross", "ballot x"],
        0x2718: ["heavy cross"],
        0x2605: ["star", "black star"],
        0x2606: ["star outline", "white star"],
        0x2665: ["heart"],
        0x2764: ["heavy heart"],
        0x2610: ["checkbox", "empty box", "ballot box"],
        0x2611: ["checked box", "ticked box"],
        0x2612: ["crossed box"],
        0x2318: ["command", "cmd", "place of interest"],
        0x2325: ["option", "alt"],
        0x21E7: ["shift"],
        0x2303: ["control", "ctrl"],
        0x232B: ["delete", "backspace"],
        0x23CE: ["return", "enter"],
        0x238B: ["escape", "esc"],
        0x2423: ["space", "visible space"],
        0x00BD: ["half", "1/2"],
        0x00BC: ["quarter", "1/4"],
        0x00BE: ["three quarters", "3/4"],
        0x2153: ["third", "1/3"],
        0x00B2: ["squared", "superscript 2"],
        0x00B3: ["cubed", "superscript 3"],
        0x2116: ["numero", "number sign", "no."],
        0x2103: ["celsius"],
        0x2109: ["fahrenheit"],
        0x266A: ["music note", "eighth note"],
        0x266B: ["music notes", "beamed notes"],
        0x266D: ["flat"],
        0x266F: ["sharp"],
        0x26A0: ["warning"],
        0x2600: ["sun"],
        0x2601: ["cloud"],
        0x2602: ["umbrella"],
        0x2603: ["snowman"],
        0x2744: ["snowflake"],
        0x260E: ["telephone", "phone"],
        0x2615: ["coffee", "hot beverage"],
        0x2620: ["skull"],
        0x262F: ["yin yang"],
        0x263A: ["smiley", "smile"],
        0x2639: ["frown", "sad"],
        0x2640: ["female", "venus"],
        0x2642: ["male", "mars"],
        0x2660: ["spade"],
        0x2663: ["club"],
        0x2666: ["diamond"],
        0x25CF: ["black circle", "filled circle"],
        0x25CB: ["white circle", "circle"],
        0x25A0: ["black square", "filled square"],
        0x25A1: ["white square", "square"],
        0x25B6: ["play", "right triangle"],
        0x25C0: ["left triangle"],
        0x25B2: ["up triangle"],
        0x25BC: ["down triangle"],
    ]

    private static func build() -> [UnicodeSymbol] {
        var out: [UnicodeSymbol] = []
        var seen = Set<UInt32>()
        // Alias-bearing symbols first, so a tie between a named favourite and
        // an obscure neighbour resolves toward the one a writer asked for.
        for value in aliases.keys.sorted() {
            if let symbol = make(value) {
                out.append(symbol)
                seen.insert(value)
            }
        }
        for range in ranges {
            for value in range where !seen.contains(value) {
                if let symbol = make(value) {
                    out.append(symbol)
                    seen.insert(value)
                }
            }
        }
        return out
    }

    private static func make(_ value: UInt32) -> UnicodeSymbol? {
        guard let scalar = Unicode.Scalar(value), let rawName = scalar.properties.name else { return nil }
        guard scalar.properties.generalCategory != .control, scalar.properties.generalCategory != .format
        else { return nil }
        let character = String(Character(scalar))
        // A canonical singleton (OHM SIGN, KELVIN SIGN, ANGSTROM SIGN) is the
        // same string as the letter it decomposes to; the letter is kept.
        guard character.precomposedStringWithCanonicalMapping.unicodeScalars.first?.value == value
        else { return nil }
        return UnicodeSymbol(
            character: character,
            name: titleCase(rawName),
            aliases: aliases[value] ?? [])
    }

    private static func titleCase(_ unicodeName: String) -> String {
        unicodeName.lowercased().split(separator: " ")
            .map { word -> String in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
