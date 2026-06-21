//
//  PlatformClassifier.swift
//  Clip
//

import Foundation

/// The result of classifying a URL by platform. Lives in ReaderKit so the main
/// app AND the extensions classify identically from one source of truth.
struct PlatformClassification: Equatable {
    let platform: ContentPlatform
    let itemID: String?
    let sourceService: MusicProvider?
}

/// Recognizes a URL's content platform from its host (with common variants) and
/// extracts the item id.
///
/// THIN SHIM over `PlatformRecognizer` (the single declarative URL→platform rule
/// table, the one authority since Stage 3). Kept only because several call sites
/// (`PasteboardSuggester`, `MediaDownload`, `BypassGate`, `PlatformRegistry`) still
/// speak `PlatformClassification`; new code should call `PlatformRecognizer.recognize`
/// directly. The former hand-written host/path ladder lived here — it now lives as
/// rule rows in `PlatformRecognizer`, so there's no duplicate logic to drift.
enum PlatformClassifier {

    static func classify(_ urlString: String) -> PlatformClassification? {
        guard let recognized = PlatformRecognizer.recognize(urlString) else { return nil }
        return PlatformClassification(
            platform: recognized.platform, itemID: recognized.itemID, sourceService: recognized.service)
    }
}
