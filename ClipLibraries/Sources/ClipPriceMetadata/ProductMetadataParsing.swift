import Foundation

public struct ParsedProductMetadata: Equatable, Sendable {
    public let name: String
    public let price: Decimal?
    public let currency: String?

    public init(name: String, price: Decimal?, currency: String?) {
        self.name = name
        self.price = price
        self.currency = currency
    }
}

public enum ProductMetadataParsing {
    public static func firstJSONLDProduct(in html: String) -> ParsedProductMetadata? {
        let pattern = #"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) where match.numberOfRanges > 1 {
            guard let dataRange = Range(match.range(at: 1), in: html),
                  let data = String(html[dataRange]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let product = findProduct(in: object),
                  let name = product["name"] as? String, !name.isEmpty
            else { continue }
            let offer = (product["offers"] as? [String: Any]) ?? ((product["offers"] as? [[String: Any]])?.first)
            let rawPrice = offer?["price"]
            let price = decimal(rawPrice)
            let currency = offer?["priceCurrency"] as? String
            return ParsedProductMetadata(name: name, price: price, currency: currency)
        }
        return nil
    }

    private static func findProduct(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            let type = dictionary["@type"] as? String
            if type?.caseInsensitiveCompare("Product") == .orderedSame { return dictionary }
            for value in dictionary.values { if let product = findProduct(in: value) { return product } }
        }
        if let array = object as? [Any] {
            for value in array { if let product = findProduct(in: value) { return product } }
        }
        return nil
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let number as NSNumber: return number.decimalValue
        case let string as String: return Decimal(string: string)
        default: return nil
        }
    }
}
