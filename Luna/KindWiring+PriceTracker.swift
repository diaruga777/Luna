//
//  KindWiring+PriceTracker.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors this
//  app's target links. EXACTLY ONE KindWiring variant is compiled into each
//  app target (the other variants are excluded via the synchronized group's
//  per-target membership exceptions) — the registry mirrors the link set.
//

import LunaIngest
import LunaPriceIngest

enum KindWiring {
    static func install() {
        IngestKindProcessors.product = ProductIngestProcessor()
    }
}
