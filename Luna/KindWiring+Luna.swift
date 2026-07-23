//
//  KindWiring+Luna.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors this
//  app's target links. EXACTLY ONE KindWiring variant is compiled into each
//  app target (the other variants are excluded via the synchronized group's
//  per-target membership exceptions) — the registry mirrors the link set.
//

import LunaArticleIngest
import LunaIngest
import LunaPriceIngest

enum KindWiring {
    static func install() {
        IngestKindProcessors.article = ArticleIngestProcessor()
        IngestKindProcessors.product = ProductIngestProcessor()
        // The central Luna app is the only surface whose card deck contains
        // non-article cards; give them their tap routing.
        NonArticleCardOpening.install()
    }
}
