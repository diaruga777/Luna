//
//  ShoppingSites.swift
//  ReaderKit
//

import Foundation

/// The source-of-truth host list for general-retailer product classification
/// (`.product(.knownShopHost)`). Amazon storefronts are handled separately by
/// `AmazonPriceRule.storefrontHosts` (they also feed the currency rules); this
/// list is every OTHER known retailer / marketplace.
///
/// Matching is SUFFIX-based (`host == domain || host.hasSuffix(".domain")`):
/// one base domain covers all subdomains but NOT sibling TLDs, so each
/// regional storefront (`ebay.de`, `mediamarkt.es`, `flipkart.com`) is listed
/// explicitly.
enum ShoppingSites {
    static let retailers: [String] = [
        // ── US big-box & general merchandise ─────────────────────────────
        "target.com", "walmart.com", "bestbuy.com", "costco.com",
        "samsclub.com", "bjs.com", "kohls.com", "macys.com",
        "nordstrom.com", "nordstromrack.com", "bloomingdales.com",
        "jcpenney.com", "dillards.com", "saksfifthavenue.com",
        "neimanmarcus.com", "qvc.com", "hsn.com", "overstock.com",
        "wayfair.com", "homedepot.com", "lowes.com", "menards.com",
        "acehardware.com", "harborfreight.com", "tractorsupply.com",
        "containerstore.com", "bedbathandbeyond.com", "crateandbarrel.com",
        "westelm.com", "potterybarn.com", "williams-sonoma.com",
        "cb2.com", "anthropologie.com", "urbanoutfitters.com",
        "ikea.com", "article.com", "allmodern.com", "joybird.com",

        // ── US electronics & specialty ───────────────────────────────────
        "newegg.com", "bhphotovideo.com", "adorama.com", "microcenter.com",
        "tigerdirect.com", "frys.com", "crutchfield.com", "sweetwater.com",
        "guitarcenter.com", "gamestop.com", "razer.com", "corsair.com",

        // ── US fashion, beauty, sporting ─────────────────────────────────
        "gap.com", "oldnavy.com", "bananarepublic.com", "jcrew.com",
        "nike.com", "adidas.com", "underarmour.com", "lululemon.com",
        "patagonia.com", "thenorthface.com", "rei.com", "dickssportinggoods.com",
        "footlocker.com", "finishline.com", "asos.com", "zara.com",
        "hm.com", "uniqlo.com", "forever21.com", "express.com",
        "abercrombie.com", "hollisterco.com", "victoriassecret.com",
        "sephora.com", "ulta.com", "glossier.com",
        "warbyparker.com", "everlane.com", "madewell.com", "revolve.com",
        "ssense.com", "farfetch.com", "net-a-porter.com", "mrporter.com",
        "shopbop.com", "nordstrom.ca", "stockx.com", "goat.com",
        "grailed.com", "poshmark.com", "thredup.com", "therealreal.com",
        "depop.com", "mercari.com",

        // ── US marketplaces, pets, misc ──────────────────────────────────
        "ebay.com", "etsy.com", "chewy.com", "petco.com", "petsmart.com",
        "zappos.com", "6pm.com", "backcountry.com", "moosejaw.com",
        "wish.com", "groupon.com", "reverb.com",
        "1stdibs.com", "chairish.com", "houzz.com", "build.com",
        "autozone.com", "rockauto.com", "tirerack.com", "carparts.com",
        "advanceautoparts.com", "oreillyauto.com", "napaonline.com",
        "officedepot.com", "staples.com", "quill.com", "uline.com",
        "grainger.com", "mcmaster.com", "digikey.com", "mouser.com",
        "sparkfun.com", "adafruit.com",

        // ── Global cross-border marketplaces ─────────────────────────────
        "aliexpress.com", "aliexpress.us", "alibaba.com", "1688.com",
        "temu.com", "shein.com", "romwe.com", "dhgate.com",
        "banggood.com", "gearbest.com", "lightinthebox.com", "miniinthebox.com",
        "joom.com", "fruugo.com",

        // ── United Kingdom & Ireland ─────────────────────────────────────
        "ebay.co.uk", "argos.co.uk", "currys.co.uk", "johnlewis.com",
        "very.co.uk", "ao.com", "screwfix.com", "wickes.co.uk",
        "diy.com", "homebase.co.uk", "dunelm.com", "marksandspencer.com",
        "next.co.uk", "boots.com", "superdrug.com", "selfridges.com",
        "harrods.com", "boohoo.com", "prettylittlething.com",
        "missguided.co.uk", "river-island.com", "newlook.com",
        "sportsdirect.com", "jdsports.co.uk", "schuh.co.uk", "office.co.uk",
        "thehut.com", "myprotein.com", "lookfantastic.com", "debenhams.com",
        "littlewoods.com", "studio.co.uk", "matalan.co.uk", "tesco.com",
        "sainsburys.co.uk", "ocado.com", "waitrose.com", "smythstoys.com",
        "thetoyshop.com", "scan.co.uk", "overclockers.co.uk", "ebuyer.com",
        "box.co.uk", "novatech.co.uk",

        // ── Germany, Austria, Switzerland ────────────────────────────────
        "ebay.de", "otto.de", "zalando.de", "mediamarkt.de", "saturn.de",
        "notebooksbilliger.de", "alternate.de", "cyberport.de", "conrad.de",
        "lidl.de", "aldi.de", "kaufland.de", "real.de", "tchibo.de",
        "thomann.de", "bonprix.de", "aboutyou.de", "baur.de",
        "weltbild.de", "idealo.de", "obi.de", "hornbach.de",
        "bauhaus.info", "ikea.de", "douglas.de", "flaconi.de",
        "zalando.at", "mediamarkt.at", "universal.at", "digitec.ch",
        "galaxus.ch", "brack.ch", "microspot.ch", "manor.ch",

        // ── France, Belgium, Netherlands ─────────────────────────────────
        "ebay.fr", "fnac.com", "darty.com", "cdiscount.com", "boulanger.com",
        "laredoute.fr", "leroymerlin.fr", "castorama.fr", "decathlon.fr",
        "rakuten.fr", "vente-privee.com", "veepee.fr", "zalando.fr",
        "sephora.fr", "ldlc.com", "materiel.net", "rueducommerce.fr",
        "carrefour.fr", "auchan.fr", "manomano.fr", "bol.com",
        "coolblue.nl", "wehkamp.nl", "mediamarkt.nl", "zalando.nl",
        "decathlon.nl", "bol.be", "coolblue.be", "mediamarkt.be",

        // ── Italy, Spain, Portugal ───────────────────────────────────────
        "ebay.it", "mediaworld.it", "unieuro.it", "euronics.it",
        "eprice.it", "monclick.it", "zalando.it", "decathlon.it",
        "ldlc.it", "ebay.es", "elcorteingles.es", "pccomponentes.com",
        "mediamarkt.es", "carrefour.es", "fnac.es", "zalando.es",
        "decathlon.es", "worten.pt", "fnac.pt", "elcorteingles.pt",

        // ── Nordics & Eastern Europe ─────────────────────────────────────
        "elgiganten.se", "komplett.se", "webhallen.com", "cdon.se",
        "netonnet.se", "power.se", "elkjop.no", "komplett.no",
        "power.no", "elgiganten.dk", "power.dk", "verkkokauppa.com",
        "gigantti.fi", "power.fi", "allegro.pl", "ceneo.pl",
        "x-kom.pl", "morele.net", "media-expert.pl", "alza.cz",
        "mall.cz", "czc.cz", "alza.sk", "emag.ro", "emag.hu",
        "emag.bg",

        // ── Australia & New Zealand ──────────────────────────────────────
        "ebay.com.au", "kmart.com.au", "target.com.au", "bigw.com.au",
        "bunnings.com.au", "jbhifi.com.au", "harveynorman.com.au",
        "thegoodguys.com.au", "officeworks.com.au", "myer.com.au",
        "davidjones.com", "catch.com.au",
        "rebelsport.com.au", "supercheapauto.com.au", "chemistwarehouse.com.au",
        "appliancesonline.com.au", "kogan.com", "pbtech.co.nz",
        "mightyape.co.nz", "thewarehouse.co.nz", "noelleeming.co.nz",
        "harveynorman.co.nz",

        // ── Canada ───────────────────────────────────────────────────────
        "ebay.ca", "bestbuy.ca", "walmart.ca", "canadiantire.ca",
        "thebay.com", "indigo.ca", "newegg.ca", "homedepot.ca",
        "rona.ca", "loblaws.ca", "sportchek.ca", "well.ca",
        "memoryexpress.com", "canadacomputers.com",

        // ── Japan, Korea, China, Asia-Pacific ────────────────────────────
        "rakuten.co.jp", "shopping.yahoo.co.jp",
        "kakaku.com", "yodobashi.com", "biccamera.com",
        "zozo.jp", "monotaro.com", "askul.co.jp", "coupang.com",
        "gmarket.co.kr", "11st.co.kr", "auction.co.kr", "ssg.com",
        "lotteon.com", "jd.com", "tmall.com", "taobao.com",
        "pinduoduo.com", "vip.com", "suning.com",
        "lazada.com", "lazada.sg", "lazada.com.my", "lazada.co.th",
        "lazada.vn", "lazada.com.ph", "shopee.com", "shopee.sg",
        "shopee.com.my", "shopee.co.th", "shopee.vn", "shopee.ph",
        "shopee.com.br", "shopee.tw", "tokopedia.com", "bukalapak.com",
        "blibli.com", "qoo10.sg", "tiki.vn", "sendo.vn", "thegioididong.com",

        // ── India ────────────────────────────────────────────────────────
        "flipkart.com", "myntra.com", "ajio.com", "snapdeal.com",
        "tatacliq.com", "nykaa.com", "meesho.com", "croma.com",
        "reliancedigital.in", "vijaysales.com", "firstcry.com",
        "pepperfry.com", "bigbasket.com", "jiomart.com", "shopclues.com",

        // ── Latin America, Middle East, Africa ───────────────────────────
        "mercadolibre.com", "mercadolibre.com.ar", "mercadolibre.com.mx",
        "mercadolivre.com.br", "americanas.com.br", "magazineluiza.com.br",
        "magazinevoce.com.br", "casasbahia.com.br", "submarino.com.br",
        "shoptime.com.br", "extra.com.br", "kabum.com.br", "netshoes.com.br",
        "dafiti.com.br", "linio.com.mx", "coppel.com", "liverpool.com.mx",
        "elektra.com.mx", "falabella.com", "ripley.com", "exito.com",
        "noon.com", "namshi.com", "jumia.com", "jumia.com.ng",
        "konga.com", "takealot.com", "trendyol.com", "hepsiburada.com",
        "n11.com", "ozon.ru", "wildberries.ru",
    ]
}
