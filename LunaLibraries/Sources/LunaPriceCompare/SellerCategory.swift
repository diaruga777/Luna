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
        let haystack = (hints + [productName])
            .joined(separator: " ")
            .lowercased()
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
    static let keywordTable: [(SellerCategory, [String])] = [
        (.appliances, ["appliance", "refrigerator", "fridge", "dishwasher", "washing machine",
                       "dryer", "microwave", "oven", "cooktop", "freezer", "vacuum"]),
        (.auto, ["automotive", "car parts", "tyre", "tire", "motor oil", "windscreen",
                 "car battery", "brake pads"]),
        (.baby, ["baby", "infant", "toddler", "nursery", "stroller", "pushchair", "nappy",
                 "diaper", "pram"]),
        (.beauty, ["beauty", "cosmetic", "makeup", "skincare", "fragrance", "perfume",
                   "shampoo", "moisturiser", "moisturizer", "lipstick"]),
        (.books, ["book", "paperback", "hardcover", "hardback", "novel", "isbn", "audiobook"]),
        (.computers, ["laptop", "notebook computer", "desktop pc", "monitor", "keyboard",
                      "mouse", "ssd", "graphics card", "cpu", "ram", "printer", "macbook"]),
        (.crafts, ["craft", "sewing", "knitting", "yarn", "scrapbook", "quilting", "beading"]),
        (.diyHardware, ["hardware", "diy", "power tool", "drill", "hammer", "screwdriver",
                        "timber", "lumber", "paint", "plumbing", "toolbox"]),
        (.electronics, ["electronics", "headphone", "earbud", "speaker", "television",
                        "camera", "smartphone", "tablet", "smartwatch", "console",
                        "soundbar", "charger"]),
        (.fashion, ["clothing", "apparel", "fashion", "dress", "shirt", "jacket", "coat",
                    "jeans", "trousers", "sweater", "hoodie", "skirt"]),
        (.furniture, ["furniture", "sofa", "couch", "armchair", "mattress", "bed frame",
                      "wardrobe", "bookcase", "dining table", "desk"]),
        (.gaming, ["gaming", "playstation", "xbox", "nintendo", "video game", "controller",
                   "steam deck"]),
        (.garden, ["garden", "lawn", "mower", "plant pot", "seeds", "greenhouse", "patio",
                   "barbecue", "bbq"]),
        (.grocery, ["grocery", "groceries", "food", "snack", "coffee beans", "tea bags",
                    "cereal", "pantry"]),
        (.health, ["health", "supplement", "vitamin", "fitness tracker", "first aid",
                   "wellness"]),
        (.home, ["home", "kitchen", "cookware", "bedding", "towel", "cushion", "curtain",
                 "storage box", "homeware", "kettle", "blender"]),
        (.jewelry, ["jewelry", "jewellery", "necklace", "bracelet", "earring", "watch",
                    "engagement ring", "pendant"]),
        (.luxury, ["luxury", "designer", "couture", "haute"]),
        (.media, ["blu-ray", "dvd", "vinyl", "cd album", "boxset", "box set"]),
        (.musicInstruments, ["guitar", "piano", "keyboard instrument", "drum kit", "violin",
                             "ukulele", "amplifier", "synthesizer"]),
        (.office, ["office", "stationery", "notebook paper", "printer paper", "pen", "pencil",
                   "binder", "envelope"]),
        (.outdoors, ["outdoor", "camping", "tent", "hiking", "backpack", "sleeping bag",
                     "kayak", "fishing"]),
        (.pets, ["pet", "dog", "cat", "puppy", "kitten", "aquarium", "litter box"]),
        (.pharmacy, ["pharmacy", "chemist", "prescription", "medicine", "painkiller",
                     "ibuprofen", "paracetamol"]),
        (.shoes, ["shoe", "sneaker", "trainer", "boot", "sandal", "loafer", "heels"]),
        (.sports, ["sport", "football", "soccer", "basketball", "running", "gym", "yoga",
                   "cycling", "bicycle", "tennis", "golf"]),
        (.toys, ["toy", "lego", "puzzle", "board game", "doll", "action figure",
                 "plush"]),
    ]
}
