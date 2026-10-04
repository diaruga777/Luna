//
//  IntentURLPrecheck.swift
//  LunaIntents
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaURLClassification
import Foundation

/// Pre-validation for a URL an App Intent was handed (today: the Shortcut's
/// on-screen URL extraction). It answers ONE question: is this a link THIS app
/// should be able to save?
///
/// That question decides whether a later failure is an error or a silence. If we
/// predicted a handleable save and the real save then fails, the intent throws —
/// the whole point of the pre-check. If the link was never ours (a product page
/// in Reader, an article in Downloader), the intent stays quiet and continues
/// with the ordinary app/screenshot decision, exactly as if no URL had been
/// supplied.
///
/// The prediction is URL-only (`Classifier.classify(url:)` with no HTML — no
/// fetch happens here) and it is deliberately coarse: platform/video links are
/// decided outright, and an otherwise-undetermined web page is predicted as an
/// article, which is what the pipeline resolves it to unless the FETCHED page
/// turns out to be a product. A prediction that misses that way ends in a
/// foreign-kind error dialog rather than a silent drop — still not silence.
public enum IntentURLPrecheck {

    public enum Verdict: Equatable {
        /// A usable URL whose predicted kind belongs to this app: a save is
        /// expected to succeed, so any failure must be reported.
        case handleable(urlString: String)
        /// A usable URL owned by a sibling app — this app was never going to
        /// save it, so there is nothing to report.
        case foreignKind(owner: LunaApp)
        /// Not a usable ingest URL at all.
        case invalid
    }

    public static func verdict(
        for urlString: String, current: LunaApp = .current
    ) -> Verdict {
        guard let url = URLUnwrapper.ingestURL(from: urlString),
              url.host?.isEmpty == false
        else { return .invalid }
        if current == .luna { return .handleable(urlString: url.absoluteString) }
        let owner = predictedOwner(
            forKind: Classifier.classify(url: url))
        switch SurfaceSupport.evaluate(owner: owner, current: current) {
        case .supported: return .handleable(urlString: url.absoluteString)
        case let .unsupported(owner): return .foreignKind(owner: owner)
        }
    }

    /// Which app a URL-only classification is expected to belong to. Mirrors
    /// `Outcome.owningApp` over the pre-fetch `ContentKind`; `.undetermined` is
    /// predicted as an article because that is where the pipeline sends a plain
    /// web page it can't classify from the URL alone.
    static func predictedOwner(forKind kind: ContentKind) -> LunaApp {
        switch kind {
        case .article, .paywalledArticle, .document, .undetermined: return .reader
        case .social, .video: return .downloader
        case .product: return .priceTracker
        }
    }
}
