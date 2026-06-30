//
//  NewsSites.swift
//  ReaderKit
//

import Foundation

/// The source-of-truth host lists for news classification, split by paywall posture.
///
/// Matching is SUFFIX-based everywhere these lists are consumed
/// (`host == domain || host.hasSuffix(".domain")`, see `KnownSite` /
/// `BypassRuleTable`): one base domain therefore covers every subdomain
/// (`www.`, `cooking.`, `edition.`, …) but NEVER a sibling TLD. Each
/// international edition or alternate-TLD variant (`nytimes.co.uk`,
/// `lemonde.fr`, `theguardian.com` vs none) is listed explicitly.
///
/// Bucketing rule (load-bearing — a mis-bucketed site is a real bug):
/// - `hardPaywall` forces a host STRAIGHT to the archive/bypass reader. ONLY
///   genuinely subscription/metered outlets belong here. A free site here is
///   broken (needlessly routed through archive.is).
/// - `free` fast-paths a host to the readable `.article` branch. Public
///   broadcasters, wire services, and open outlets belong here.
/// - When a site's posture is uncertain, it is in NEITHER list — default
///   heuristic handling is the safe fallback.
public enum NewsSites {

    /// Genuinely subscription/metered outlets worldwide. Routed to
    /// `.paywalledArticle(hardHost: true)` (archive reader only).
    public static let hardPaywall: [String] = [
        // ── United States ────────────────────────────────────────────────
        "nytimes.com", "wsj.com", "washingtonpost.com", "bloomberg.com",
        "barrons.com", "theatlantic.com",
        "wired.com", "newyorker.com", "vanityfair.com", "foreignpolicy.com",
        "foreignaffairs.com", "theinformation.com", "hbr.org", "seekingalpha.com",
        "latimes.com", "bostonglobe.com", "chicagotribune.com", "nymag.com",
        "statnews.com",
        "nationalgeographic.com", "harpers.org", "thenation.com",
        "newrepublic.com", "wired.co.uk", "sfchronicle.com", "dallasnews.com",
        "miamiherald.com", "startribune.com", "denverpost.com", "seattletimes.com",
        "philly.com", "inquirer.com", "baltimoresun.com", "newsday.com",
        "tampabay.com", "thedailyrecord.com", "nj.com", "courant.com",
        "sacbee.com", "kansascity.com", "charlotteobserver.com", "newsobserver.com",
        "post-gazette.com", "stltoday.com", "cincinnati.com",
        "dispatch.com", "freep.com", "detroitnews.com", "ajc.com",
        "houstonchronicle.com", "expressnews.com", "statesman.com",
        "azcentral.com", "ocregister.com", "mercurynews.com", "eastbaytimes.com",
        "bostonherald.com", "tennessean.com", "courier-journal.com",
        "jsonline.com", "desmoinesregister.com", "commercialappeal.com",
        "theadvocate.com", "nola.com", "post-dispatch.com", "buffalonews.com",
        "timesunion.com", "providencejournal.com", "pressherald.com",
        "concordmonitor.com", "vtdigger.org", "thebaffler.com",
        "currentaffairs.org", "lawfaremedia.org", "puck.news",
        "thedispatch.com", "thefp.com", "tabletmag.com", "reason.com",
        "nationalreview.com", "spectator.org", "americanaffairsjournal.org",
        "compactmag.com", "quillette.com", "thebulwark.com", "talkingpointsmemo.com",

        // ── United Kingdom & Ireland ─────────────────────────────────────
        "ft.com", "economist.com", "thetimes.co.uk", "thetimes.com",
        "telegraph.co.uk", "thesundaytimes.co.uk", "spectator.co.uk",
        "newstatesman.com", "prospectmagazine.co.uk", "thecritic.co.uk",
        "irishtimes.com", "independent.ie", "businesspost.ie",
        "heraldscotland.com", "scotsman.com", "pressandjournal.co.uk",

        // ── France ───────────────────────────────────────────────────────
        "lemonde.fr", "lefigaro.fr", "lesechos.fr", "mediapart.fr",
        "liberation.fr", "lopinion.fr", "latribune.fr", "marianne.net",
        "lepoint.fr", "lexpress.fr", "nouvelobs.com", "telerama.fr",
        "courrierinternational.com", "alternatives-economiques.fr",
        "contexte.com", "lest-eclair.fr", "ouest-france.fr",

        // ── Germany, Austria, Switzerland ────────────────────────────────
        "faz.net", "sueddeutsche.de", "welt.de", "handelsblatt.com",
        "zeit.de", "spiegel.de", "wiwo.de", "tagesspiegel.de",
        "manager-magazin.de", "capital.de", "bild.de", "ftd.de",
        "nzz.ch", "tagesanzeiger.ch", "lematin.ch", "letemps.ch",
        "blick.ch", "luzernerzeitung.ch", "derstandard.at", "diepresse.com",
        "kurier.at", "kleinezeitung.at",

        // ── Netherlands & Belgium ────────────────────────────────────────
        "nrc.nl", "volkskrant.nl", "trouw.nl", "fd.nl", "parool.nl",
        "telegraaf.nl", "ad.nl", "demorgen.be", "standaard.be",
        "tijd.be", "lecho.be", "lalibre.be", "lesoir.be",

        // ── Italy ────────────────────────────────────────────────────────
        "corriere.it", "repubblica.it", "lastampa.it", "ilsole24ore.com",
        "ilfattoquotidiano.it", "ilmessaggero.it", "ilgiornale.it",
        "ilfoglio.it", "milanofinanza.it", "lettera43.it",

        // ── Spain & Portugal ─────────────────────────────────────────────
        "elpais.com", "elmundo.es", "abc.es", "lavanguardia.com",
        "elconfidencial.com", "expansion.com", "eleconomista.es",
        "elperiodico.com", "larazon.es", "vozpopuli.com", "publico.pt",
        "expresso.pt", "observador.pt", "dn.pt", "jornaldenegocios.pt",

        // ── Nordics ──────────────────────────────────────────────────────
        "dn.se", "svd.se", "di.se", "expressen.se", "aftonbladet.se",
        "hd.se", "sydsvenskan.se", "vg.no", "aftenposten.no", "dn.no",
        "nettavisen.no", "dagbladet.no", "bt.no", "politiken.dk",
        "berlingske.dk", "jyllands-posten.dk", "borsen.dk", "information.dk",
        "hs.fi", "kauppalehti.fi", "is.fi", "talouselama.fi",
        "mbl.is", "frettabladid.is",

        // ── Central & Eastern Europe ─────────────────────────────────────
        "wyborcza.pl", "rp.pl", "wprost.pl", "polityka.pl",
        "ihned.cz", "hn.cz", "lidovky.cz", "denikn.cz", "sme.sk",
        "dennikn.sk", "hvg.hu", "index.hu", "telex.hu", "delo.si",
        "jutarnji.hr", "vecernji.hr", "kathimerini.gr", "tovima.gr",
        "naftemporiki.gr", "hotnews.ro", "adevarul.ro",

        // ── Australia & New Zealand ──────────────────────────────────────
        "afr.com", "theaustralian.com.au", "smh.com.au", "theage.com.au",
        "wsj.com.au", "brisbanetimes.com.au", "watoday.com.au",
        "canberratimes.com.au", "theadvertiser.com.au", "couriermail.com.au",
        "heraldsun.com.au", "dailytelegraph.com.au", "thewest.com.au",
        "themonthly.com.au", "crikey.com.au", "nzherald.co.nz",
        "stuff.co.nz", "thepost.co.nz", "newsroom.co.nz",

        // ── Canada ───────────────────────────────────────────────────────
        "theglobeandmail.com", "thestar.com", "nationalpost.com",
        "lapresse.ca", "ledevoir.com", "lesaffaires.com",
        "thewalrus.ca", "macleans.ca", "winnipegfreepress.com",
        "vancouversun.com", "ottawacitizen.com", "calgaryherald.com",
        "edmontonjournal.com", "montrealgazette.com", "thespec.com",

        // ── Japan, Korea, Greater China, Asia ────────────────────────────
        "nikkei.com", "asahi.com", "yomiuri.co.jp", "mainichi.jp",
        "sankei.com", "japantimes.co.jp", "toyokeizai.net",
        "joongang.co.kr", "chosun.com", "donga.com", "hankyung.com",
        "mk.co.kr", "koreaherald.com", "koreatimes.co.kr",
        "scmp.com", "caixinglobal.com", "thestandard.com.hk",
        "straitstimes.com", "businesstimes.com.sg", "todayonline.com",
        "bangkokpost.com", "thejakartapost.com", "vir.com.vn",
        "thehindu.com", "thehindubusinessline.com", "livemint.com",
        "business-standard.com", "financialexpress.com", "telegraphindia.com",
        "deccanherald.com", "thewire.in", "theprint.in",
        "dawn.com", "thedailystar.net", "himalmag.com",

        // ── Middle East & Africa ─────────────────────────────────────────
        "haaretz.com", "haaretz.co.il", "themarker.com", "timesofisrael.com",
        "jpost.com", "thenationalnews.com", "arabnews.com",
        "gulfnews.com", "mada.media", "madamasr.com",
        "businessdaily.co.ke", "businesslive.co.za", "dailymaverick.co.za",
        "mg.co.za", "premiumtimesng.com", "businessday.ng",

        // ── Latin America ────────────────────────────────────────────────
        "clarin.com", "lanacion.com.ar", "infobae.com", "eluniversal.com.mx",
        "reforma.com", "elfinanciero.com.mx", "expansion.mx",
        "estadao.com.br", "folha.uol.com.br", "valor.globo.com",
        "oglobo.globo.com", "gazetadopovo.com.br", "exame.com",
        "eltiempo.com", "elespectador.com", "semana.com",
        "emol.com", "latercera.com", "df.cl", "elcomercio.pe",
        "gestion.pe", "elobservador.com.uy",
    ]

    /// Public broadcasters, wire services, and free/open outlets worldwide.
    /// Routed to `.article` (fast-path, skip the heuristic phase).
    public static let free: [String] = [
        // ── Mostly-free / metered (must NOT be forced to the archive reader) ──
        "businessinsider.com", "insider.com", "marketwatch.com", "fortune.com",
        // ── Wire services & global broadcasters ──────────────────────────
        "reuters.com", "apnews.com", "afp.com",
        "bbc.com", "bbc.co.uk", "aljazeera.com", "aljazeera.net",
        "dw.com", "france24.com", "rfi.fr", "euronews.com",
        "rt.com", "trtworld.com", "cgtn.com", "sputnikglobe.com",

        // ── United States ────────────────────────────────────────────────
        "cnn.com", "nbcnews.com", "abcnews.go.com", "cbsnews.com",
        "msnbc.com", "usatoday.com", "npr.org", "pbs.org",
        "propublica.org", "theintercept.com", "vox.com", "slate.com",
        "buzzfeednews.com", "huffpost.com", "thehill.com", "salon.com",
        "motherjones.com", "theverge.com", "techcrunch.com", "arstechnica.com",
        "engadget.com", "gizmodo.com", "theconversation.com", "404media.co",
        "restofworld.org", "themarkup.org", "grist.org", "insideclimatenews.org",
        "kffhealthnews.org", "themarshallproject.org", "factcheck.org",
        "snopes.com", "voanews.com", "c-span.org", "govexec.com",
        "rollcall.com", "courthousenews.com", "democracynow.org",
        "commondreams.org", "truthout.org", "jacobin.com", "axios.com",
        "semafor.com", "deadline.com",
        "variety.com", "hollywoodreporter.com", "billboard.com",
        "rollingstone.com", "pitchfork.com", "espn.com", "cbssports.com",
        "bleacherreport.com", "weather.com", "accuweather.com",

        // ── United Kingdom & Ireland ─────────────────────────────────────
        "theguardian.com", "guardian.co.uk", "metro.co.uk",
        "standard.co.uk", "independent.co.uk",
        "mirror.co.uk", "express.co.uk", "dailymail.co.uk", "thesun.co.uk",
        "manchestereveningnews.co.uk", "liverpoolecho.co.uk",
        "walesonline.co.uk", "rte.ie", "thejournal.ie", "breakingnews.ie",
        "channel4.com", "sky.com", "news.sky.com", "itv.com",

        // ── Europe ───────────────────────────────────────────────────────
        "tagesschau.de", "deutschlandfunk.de", "n-tv.de", "focus.de",
        "stern.de", "taz.de", "heise.de", "golem.de",
        "20minutes.fr", "francetvinfo.fr", "humanite.fr",
        "rai.it", "ansa.it", "open.online", "fanpage.it",
        "rtve.es", "20minutos.es", "eldiario.es", "elsaltodiario.com",
        "nos.nl", "nu.nl", "rtbf.be", "vrt.be",
        "sverigesradio.se", "svt.se", "nrk.no", "dr.dk",
        "yle.fi", "tvn24.pl", "onet.pl", "wp.pl",
        "irozhlas.cz", "ct24.ceskatelevize.cz", "rtvslo.si",
        "ert.gr",

        // ── Australia, NZ, Canada ────────────────────────────────────────
        "abc.net.au", "news.com.au", "9news.com.au", "7news.com.au",
        "sbs.com.au", "theguardian.com.au", "theconversation.com.au",
        "rnz.co.nz", "1news.co.nz", "cbc.ca", "ctvnews.ca",
        "globalnews.ca", "thetyee.ca", "rabble.ca", "nationalobserver.com",
        "ici.radio-canada.ca",

        // ── Asia, Middle East, Africa, Latin America ─────────────────────
        "channelnewsasia.com", "ndtv.com", "indianexpress.com",
        "hindustantimes.com", "timesofindia.indiatimes.com", "scroll.in",
        "thequint.com", "rappler.com", "inquirer.net", "abs-cbn.com",
        "tempo.co", "kompas.com", "vnexpress.net", "tuoitrenews.vn",
        "khaleejtimes.com", "middleeasteye.net", "al-monitor.com",
        "i24news.tv", "ynetnews.com", "egyptindependent.com",
        "news24.com", "iol.co.za", "theeastafrican.co.ke", "nation.africa",
        "punchng.com", "vanguardngr.com", "graphic.com.gh", "allafrica.com",
        "globo.com", "g1.globo.com", "uol.com.br",
        "milenio.com", "jornada.com.mx", "telesurenglish.net",
        "buenosairesherald.com", "batimes.com.ar", "mercopress.com",

        // ── Reference ────────────────────────────────────────────────────
        "wikipedia.org", "wikinews.org",
    ]
}
