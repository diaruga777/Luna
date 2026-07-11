//
//  ScreenshotDoublePress.swift
//  LunaIntents
//

import LunaStorage
import LunaSend
import Foundation

/// Pure double-press detection for the Save App Intent's screenshot path:
/// given the digest of the JUST-captured screenshot and the previously
/// recorded snapshot (`ScreenshotDoublePressStore.last()`), decides whether
/// this run is a near-immediate repeat of the last one (skip the model,
/// repeat its save) or a genuinely new screenshot (run the model).
///
/// Reuses `SavePressPolicy.intentDoublePressWindow` (7 s) — the same window
/// the Action Button's legacy double-save regime uses — for recency, and
/// `ScreenshotDigest.isSimilar` for visual similarity. Both conditions must
/// hold; either alone (an old-but-identical screenshot, or a fresh-but-
/// different one) means "run the model."
public enum ScreenshotDoublePress {
    public enum Decision: Equatable {
        /// Treat this run as a repeat of the previous screenshot save — skip
        /// the model and re-run the double-save action for this URL.
        case treatAsDoublePress(savedURLString: String)
        /// Run the model — no previous snapshot, or it's too old, or it's
        /// visually different from this one.
        case runModel
    }

    public static func decide(
        newDigest: Data,
        previous: ScreenshotDoublePressSnapshot?,
        now: Date = Date()
    ) -> Decision {
        guard let previous else { return .runModel }
        guard now.timeIntervalSince(previous.date) < SavePressPolicy.intentDoublePressWindow else {
            return .runModel
        }
        guard ScreenshotDigest.isSimilar(newDigest, previous.digest) else { return .runModel }
        return .treatAsDoublePress(savedURLString: previous.savedURLString)
    }
}
