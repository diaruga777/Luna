//
//  AmazonStorefronts.swift
//  LunaURLClassification
//

/// Every current Amazon retail storefront and its local transaction currency.
/// The hostname registry is deliberately explicit (rather than accepting any
/// `amazon.*` domain) to prevent lookalike hosts from becoming price sources.
///
/// Lives in the URL-classification tier because the host LIST is
/// classification data (the deterministic shop table); the per-storefront
/// CURRENCY is consumed by the price extraction rule in `LunaPriceIngest`.
public enum AmazonStorefronts {
    public static let storefronts: [(host: String, currency: String)] = [
        ("amazon.com", "USD"), ("amazon.ca", "CAD"), ("amazon.com.mx", "MXN"),
        ("amazon.com.br", "BRL"), ("amazon.co.uk", "GBP"), ("amazon.de", "EUR"),
        ("amazon.fr", "EUR"), ("amazon.it", "EUR"), ("amazon.es", "EUR"),
        ("amazon.nl", "EUR"), ("amazon.se", "SEK"), ("amazon.pl", "PLN"),
        ("amazon.com.tr", "TRY"), ("amazon.com.be", "EUR"), ("amazon.ie", "EUR"),
        ("amazon.co.jp", "JPY"), ("amazon.in", "INR"), ("amazon.com.au", "AUD"),
        ("amazon.sg", "SGD"), ("amazon.ae", "AED"), ("amazon.sa", "SAR"),
        ("amazon.eg", "EGP"), ("amazon.co.za", "ZAR"),
    ]

    public static let hosts = storefronts.map(\.host)

    /// The storefront matching `host` (exact or subdomain), or nil for
    /// lookalikes such as `amazon.scam.com`.
    public static func storefront(for host: String?) -> (host: String, currency: String)? {
        guard var normalized = host?.lowercased() else { return nil }
        if normalized.hasSuffix(".") { normalized.removeLast() }
        return storefronts.first { storefront in
            normalized == storefront.host || normalized.hasSuffix("." + storefront.host)
        }
    }
}
