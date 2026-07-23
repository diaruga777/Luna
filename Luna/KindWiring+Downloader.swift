//
//  KindWiring+Downloader.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors this
//  app's target links. EXACTLY ONE KindWiring variant is compiled into each
//  app target (the other variants are excluded via the synchronized group's
//  per-target membership exceptions) — the registry mirrors the link set.
//

enum KindWiring {
    static func install() {
        // Media needs no web-processing pipeline stage: platform recognition
        // is URL-only classification, and download handling runs post-save.
    }
}
