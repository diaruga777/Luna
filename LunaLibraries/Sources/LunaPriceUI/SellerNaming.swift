//
//  SellerNaming.swift
//  LunaPriceUI
//

import Foundation
import LunaModels
import LunaPriceCompare

/// What a seller is CALLED, everywhere Luna shows one: the seller rows on the
/// product card and in the extension editor, and the comparison document the
/// Action Button intents hand back.
///
/// The bundled seller directory already knows the answer — it is how the fan-out
/// labels a retailer it searched — but a tracker persists URLs, not seller ids,
/// so the name has to be recovered from the host. Directory first ("JB Hi-Fi",
/// "Best Buy"), then the registrable domain with its public suffix dropped and
/// its first letter raised ("binglee.com.au" → "Binglee"). A row reading
/// "binglee.com.au" was never the seller's name; it was Luna showing its work.
public enum SellerNaming {

    /// The display name for the seller hosting `urlString`.
    public static func displayName(forURLString urlString: String) -> String {
        guard let host = URL(string: urlString)?.host else { return urlString }
        return displayName(forHost: host)
    }

    /// The display name for a bare host.
    public static func displayName(forHost host: String) -> String {
        if let known = try? SellerDirectory.bundled().seller(forHost: host)?.name, !known.isEmpty {
            return known
        }
        let domain = ProductIdentityMatching.registrableDomain(host)
        guard let label = domain.split(separator: ".").first, !label.isEmpty else { return host }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// The letter a seller's placeholder badge carries — its first alphanumeric
    /// character, uppercased. "•" only for a name with none at all, so the badge
    /// is never blank.
    public static func initial(forName name: String) -> String {
        guard let character = name.first(where: { $0.isLetter || $0.isNumber }) else { return "•" }
        return String(character).uppercased()
    }
}
