//
//  KnownPaywallHosts.swift
//  ClipPaywallBypass
//

import Foundation

/// The Bypass-Paywalls-Clean supported-host list, used (only when the extra-unlock
/// toggle is on) to let a site the generic gate didn't flag still enter the unlock
/// flow. Pure host matching, split out of the WebKit `PaywallUnlockRules` so the
/// bypass-strategy logic can consult it without depending on the UI layer.
public enum KnownPaywallHosts {
    /// Whether `url`'s host is a known paywall host (apex + any subdomain,
    /// trailing dot tolerated).
    public static func isKnown(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Base domains supported (a representative cross-section — USA national/
    /// business/tech/magazines, the big publisher groups, UK/EU, AU/Asia). Used only
    /// as an extra toggle-on paywall signal; duplicates with `NewsSites.hardPaywall`
    /// are harmless.
    public static let hosts: Set<String> = [
        // USA national / business
        "wsj.com", "nytimes.com", "washingtonpost.com", "bloomberg.com", "reuters.com",
        "barrons.com", "businessinsider.com", "cnbc.com", "forbes.com", "fortune.com",
        "marketwatch.com", "hbr.org", "inc.com", "fastcompany.com", "entrepreneur.com",
        "adweek.com", "benzinga.com", "investors.com", "law.com", "qz.com", "spglobal.com",
        "citywire.com", "thestreet.com", "morningstar.com", "ft.com", "economist.com",
        // Arizent / Crain groups
        "americanbanker.com", "accountingtoday.com", "bondbuyer.com", "financial-planning.com",
        "nationalmortgagenews.com", "adage.com", "autonews.com", "chicagobusiness.com",
        "crainsnewyork.com", "crainsdetroit.com", "modernhealthcare.com", "pionline.com",
        "plasticsnews.com", "bizjournals.com",
        // Tech / science
        "wired.com", "technologyreview.com", "nationalgeographic.com", "nature.com",
        "newscientist.com", "popsci.com", "science.org", "sciencenews.org",
        "scientificamerican.com", "the-scientist.com", "tomshardware.com", "discovermagazine.com",
        "interestingengineering.com", "medscape.com", "insidehighered.com", "timeshighereducation.com",
        // Magazines / blogs
        "theatlantic.com", "thedailybeast.com", "foreignaffairs.com", "foreignpolicy.com",
        "harpers.org", "newsweek.com", "politico.com", "slate.com", "thenation.com",
        "newrepublic.com", "nybooks.com", "theweek.com", "vice.com", "al-monitor.com",
        "axios.com", "theamericanconservative.com", "pastemagazine.com",
        // Condé Nast
        "architecturaldigest.com", "bonappetit.com", "cntraveler.com", "epicurious.com",
        "gq.com", "newyorker.com", "vanityfair.com", "vogue.com",
        // Hearst
        "cosmopolitan.com", "elle.com", "elledecor.com", "esquire.com", "goodhousekeeping.com",
        "harpersbazaar.com", "housebeautiful.com", "menshealth.com", "popularmechanics.com",
        "prevention.com", "roadandtrack.com", "runnersworld.com", "townandcountrymag.com",
        "womenshealthmag.com", "bicycling.com", "delish.com", "oprahdaily.com",
        // Penske / Vox / others
        "billboard.com", "rollingstone.com", "variety.com", "wwd.com", "sportico.com",
        "nymag.com", "thecut.com", "theverge.com", "vox.com", "vulture.com", "curbed.com",
        // USA local + groups
        "latimes.com", "bostonglobe.com", "seattletimes.com", "nydailynews.com", "nypost.com",
        "ajc.com", "azcentral.com", "cincinnati.com", "courier-journal.com", "desmoinesregister.com",
        "detroitnews.com", "dispatch.com", "freep.com", "indystar.com", "jsonline.com",
        "northjersey.com", "tennessean.com", "baltimoresun.com", "chicagotribune.com",
        "courant.com", "orlandosentinel.com", "sun-sentinel.com", "mcall.com",
        // Canada
        "theglobeandmail.com", "ledevoir.com", "thelogic.co", "winnipegfreepress.com",
        // UK / Ireland
        "telegraph.co.uk", "thetimes.com", "observer.co.uk", "irishexaminer.com",
        "decanter.com", "fnlondon.com", "lrb.co.uk", "newstatesman.com", "spectator.co.uk",
        // Europe
        "spiegel.de", "faz.net", "sueddeutsche.de", "handelsblatt.com", "welt.de", "zeit.de",
        "lemonde.fr", "lefigaro.fr", "lexpress.fr", "lepoint.fr", "liberation.fr",
        "elpais.com", "elmundo.es", "elconfidencial.com", "corriere.it", "repubblica.it",
        "ilsole24ore.com", "nrc.nl", "telegraaf.nl",
        // Asia / Australia
        "asia.nikkei.com", "japantimes.co.jp", "thehindu.com", "hindustantimes.com",
        "indianexpress.com", "smh.com.au", "theage.com.au", "afr.com", "nzherald.co.nz",
    ]
}
