//
//  EmbeddedJSONBlobs.swift
//  ReaderKit
//

import Foundation
import SwiftSoup

/// The two JSON-blob sources shared by every embedded-page-state scanner: a
/// Next.js `__NEXT_DATA__` script (richest, tried first), then any other
/// `application/json` script. `ProductPageDetector` layers a third, inline
/// `window.__X__ = {…}` source on top for its own scan; `ProductMetadataExtractor`
/// uses just these two.
enum EmbeddedJSONBlobs {
    static func nextDataAndJSONScripts(in document: Document) -> [String] {
        var blobs: [String] = []
        if let next = try? document.select("script#__NEXT_DATA__").first(),
           let json = try? next.html().trimmedNonEmpty {
            blobs.append(json)
        }
        if let scripts = try? document.select("script[type=application/json]") {
            for script in scripts {
                guard let json = try? script.html().trimmedNonEmpty else { continue }
                blobs.append(json)
            }
        }
        return blobs
    }
}
