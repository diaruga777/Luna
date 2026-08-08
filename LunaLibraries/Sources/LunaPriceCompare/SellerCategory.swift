//
//  SellerCategory.swift
//  LunaPriceCompare
//

import Foundation

/// The FIXED taxonomy every directory entry's `categories` must draw from, and
/// the only vocabulary category inference may produce. Fixed rather than
/// free-form because both sides of a category overlap have to mean the same
/// thing for the overlap bonus to mean anything.
public enum SellerCategory: String, CaseIterable, Codable, Sendable {
    case appliances
    case auto
    case baby
    case beauty
    case books
    case computers
    case crafts
    case diyHardware = "diy-hardware"
    case electronics
    case fashion
    case furniture
    case gaming
    case garden
    /// A mass merchant selling across the taxonomy — the fallback universe when
    /// nothing about the product suggests a category.
    case general
    case grocery
    case health
    case home
    case jewelry
    case luxury
    case media
    case musicInstruments = "music-instruments"
    case office
    case outdoors
    case pets
    case pharmacy
    case shoes
    case sports
    case toys
}

/// Maps free-text category hints (JSON-LD `category`, breadcrumb trail, product
/// name words) onto the fixed taxonomy.
///
/// Deliberately keyword-based and local: the fan-out runs inside a Safari appex
/// with a ~20s budget, so "which kind of shop sells this?" has to be answered
/// from the page text already in hand. Being wrong is cheap — an unrecognized
/// product simply falls back to mass merchants, which is where most things are
/// sold anyway.
public enum SellerCategoryInference {

    /// The taxonomy categories `hints` and `productName` suggest.
    ///
    /// `sourceCategories` are the SOURCE retailer's own directory categories,
    /// unioned in with `general` dropped: a page on a specialist site is
    /// evidence about the product even when its text says nothing, while
    /// `general` from a mass merchant says nothing at all.
    ///
    /// An empty result means "uncategorized", which the selector reads as
    /// "mass merchants only" rather than "everything".
    public static func categories(
        hints: [String], productName: String, sourceCategories: [String] = []
    ) -> Set<String> {
        let haystack = normalizedHaystack(from: hints + [productName])
        var found: Set<String> = []
        for (category, keywords) in keywordTable {
            for keyword in keywords where containsWord(haystack, keyword) {
                found.insert(category.rawValue)
                break
            }
        }
        for raw in sourceCategories where raw != SellerCategory.general.rawValue {
            if SellerCategory(rawValue: raw) != nil { found.insert(raw) }
        }
        return found
    }

    /// Flattens the raw hint strings into one lowercase haystack the keyword
    /// table can be run over.
    ///
    /// Real hints do not arrive as tidy taxonomy words. They are breadcrumb
    /// trails (`Home › Books › Self-Help`), JSON-LD `category` strings
    /// (`Books/Nonfiction`), and product titles, in whatever case the retailer
    /// wrote them — so separators become spaces and everything is lowercased.
    ///
    /// The load-bearing part is the SINGULAR/PLURAL pass. `containsWord` already
    /// lets a singular keyword fire on a plural hint (`book` on `books`), but
    /// not the reverse and not the irregular endings: a hint of `groceries`
    /// would never reach the keyword `grocery`, and `accessories` never reaches
    /// `accessory`. Each token is therefore ALSO emitted in its de-pluralized
    /// form, so both directions work regardless of which side wrote the plural.
    static func normalizedHaystack(from parts: [String]) -> String {
        // A hyphen is NOT a separator: it is part of the vocabulary
        // ("blu-ray", "first aid"-adjacent model numbers), and only a spaced
        // dash is ever a breadcrumb delimiter.
        let separators = CharacterSet(charactersIn: ">|/\\,;:•·»→\u{00A0}")
        let flattened = parts
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: " - ", with: " ")
            .replacingOccurrences(of: " – ", with: " ")
            .replacingOccurrences(of: " — ", with: " ")
            .components(separatedBy: separators)
            .joined(separator: " ")
        var tokens: [String] = []
        for token in flattened.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(token)
            tokens.append(word)
            if let singular = depluralized(word), singular != word { tokens.append(singular) }
        }
        return tokens.joined(separator: " ")
    }

    /// The singular of a simple English plural, or nil when the word is not one.
    /// Deliberately tiny — this exists to bridge hint vocabulary to the keyword
    /// table, not to conjugate English.
    static func depluralized(_ word: String) -> String? {
        guard word.count > 3 else { return nil }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ses") || word.hasSuffix("xes") || word.hasSuffix("ches")
            || word.hasSuffix("shes") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") {
            return String(word.dropLast())
        }
        return nil
    }

    /// Word-boundary containment, with a plural "s" allowed at the end.
    ///
    /// The boundary matters in both directions: "pet" must not fire on
    /// "carpet" and "dog" must not fire on "dogma", but "headphone" absolutely
    /// must fire on "headphones" — product titles are written in plurals far
    /// more often than the keyword table is.
    public static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetter
            if beforeOK, isWordEnd(haystack, at: range.upperBound) { return true }
            guard range.upperBound < haystack.endIndex else { return false }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return false
    }

    private static func isWordEnd(_ haystack: String, at index: String.Index) -> Bool {
        guard index < haystack.endIndex else { return true }
        if !haystack[index].isLetter { return true }
        guard haystack[index] == "s" else { return false }
        let next = haystack.index(after: index)
        return next == haystack.endIndex || !haystack[next].isLetter
    }

    /// Sorted by category so iteration order (and therefore the result) never
    /// depends on dictionary hashing.
    ///
    /// Each list carries both the *product* words a title would use and the
    /// *shelf* words a breadcrumb or a JSON-LD `category` would use — they are
    /// rarely the same word. A page that says nothing but `Category: Home &
    /// Kitchen` has to reach `home`, and a title that says nothing but "Atomic
    /// Habits" reaches `books` only through its breadcrumb.
    static let keywordTable: [(SellerCategory, [String])] = [
        (.appliances, ["appliance", "refrigerator", "fridge", "dishwasher", "washing machine",
                       "dryer", "microwave", "oven", "cooktop", "freezer", "vacuum",
                       "air fryer", "washer"]),
        (.auto, ["automotive", "car parts", "tyre", "tire", "motor oil", "windscreen",
                 "car battery", "brake pads", "auto part", "vehicle", "engine oil"]),
        (.baby, ["baby", "infant", "toddler", "nursery", "stroller", "pushchair", "nappy",
                 "diaper", "pram", "car seat"]),
        (.beauty, ["beauty", "cosmetic", "makeup", "skincare", "fragrance", "perfume",
                   "shampoo", "moisturiser", "moisturizer", "lipstick", "haircare",
                   "nail polish", "toiletries"]),
        (.books, ["book", "bookstore", "paperback", "hardcover", "hardback", "novel", "isbn",
                  "audiobook", "textbook", "ebook", "e-book", "literature", "fiction",
                  "nonfiction", "non-fiction", "cookbook", "comic", "manga", "biography",
                  "self-help", "memoir"]),
        (.computers, ["laptop", "notebook computer", "desktop pc", "monitor", "keyboard",
                      "mouse", "ssd", "graphics card", "cpu", "ram", "printer", "macbook",
                      "computer", "computing", "chromebook"]),
        (.crafts, ["craft", "sewing", "knitting", "yarn", "scrapbook", "quilting", "beading",
                   "embroidery", "fabric"]),
        (.diyHardware, ["hardware", "diy", "power tool", "drill", "hammer", "screwdriver",
                        "timber", "lumber", "paint", "plumbing", "toolbox", "tool",
                        "home improvement"]),
        (.electronics, ["electronics", "headphone", "earbud", "speaker", "television",
                        "camera", "smartphone", "tablet", "smartwatch", "console",
                        "soundbar", "charger", "electronic", "audio", "headset", "earphone",
                        "tv", "hdtv"]),
        (.fashion, ["clothing", "apparel", "fashion", "dress", "shirt", "jacket", "coat",
                    "jeans", "trousers", "sweater", "hoodie", "skirt", "clothes", "garment",
                    "menswear", "womenswear", "t-shirt"]),
        (.furniture, ["furniture", "sofa", "couch", "armchair", "mattress", "bed frame",
                      "wardrobe", "bookcase", "dining table", "desk", "nightstand",
                      "dresser", "shelving"]),
        (.gaming, ["gaming", "playstation", "xbox", "nintendo", "video game", "videogame",
                   "controller", "steam deck", "gamepad"]),
        (.garden, ["garden", "lawn", "mower", "plant pot", "seeds", "greenhouse", "patio",
                   "barbecue", "bbq", "gardening", "outdoor living"]),
        (.grocery, ["grocery", "groceries", "food", "snack", "coffee beans", "tea bags",
                    "cereal", "pantry", "beverage", "drink", "candy"]),
        (.health, ["health", "supplement", "vitamin", "fitness tracker", "first aid",
                   "wellness", "nutrition", "medical", "personal care"]),
        (.home, ["home", "kitchen", "cookware", "bedding", "towel", "cushion", "curtain",
                 "storage box", "homeware", "kettle", "blender", "household", "decor"]),
        (.jewelry, ["jewelry", "jewellery", "necklace", "bracelet", "earring", "watch",
                    "engagement ring", "pendant", "wristwatch"]),
        (.luxury, ["luxury", "designer", "couture", "haute"]),
        (.media, ["blu-ray", "dvd", "vinyl", "cd album", "boxset", "box set", "movie", "film",
                  "music", "album", "soundtrack"]),
        (.musicInstruments, ["guitar", "piano", "keyboard instrument", "drum kit", "violin",
                             "ukulele", "amplifier", "synthesizer", "instrument"]),
        (.office, ["office", "stationery", "notebook paper", "printer paper", "pen", "pencil",
                   "binder", "envelope", "school supply", "stationary"]),
        (.outdoors, ["outdoor", "camping", "tent", "hiking", "backpack", "sleeping bag",
                     "kayak", "fishing", "cooler", "binoculars"]),
        (.pets, ["pet", "dog", "cat", "puppy", "kitten", "aquarium", "litter box",
                 "pet supply", "dog food", "cat food"]),
        (.pharmacy, ["pharmacy", "chemist", "prescription", "medicine", "painkiller",
                     "ibuprofen", "paracetamol"]),
        (.shoes, ["shoe", "sneaker", "trainer", "boot", "sandal", "loafer", "heels",
                  "footwear"]),
        (.sports, ["sport", "football", "soccer", "basketball", "running", "gym", "yoga",
                   "cycling", "bicycle", "tennis", "golf", "sporting good", "athletic",
                   "exercise", "workout"]),
        (.toys, ["toy", "lego", "puzzle", "board game", "doll", "action figure",
                 "plush", "building set", "figurine", "playset"]),
    ]
}
