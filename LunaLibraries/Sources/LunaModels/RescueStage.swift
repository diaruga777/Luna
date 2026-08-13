//
//  RescueStage.swift
//  LunaModels
//

import Foundation

/// How far along a URL rescue is. The engine reports one of these as it crosses
/// each boundary of its own pipeline; the failed-save card turns the reported
/// `fraction` into the eclipse bar's position.
///
/// Deliberately coarse and deliberately NOT uniformly spaced: the fractions are
/// calibrated to how long each stage actually takes (the model call dominates a
/// 90-second budget), so the bar doesn't sprint to 90% and then sit there. Lives
/// in LunaModels so the engine, the coordinator, and the card can all name it
/// without the UI tier linking `LunaURLRescue`.
public enum RescueStage: String, Codable, Sendable, CaseIterable {
    /// Accepted; nothing has happened yet.
    case queued
    /// Replaying a learned per-host rule, before any model call.
    case replayingRule
    /// Re-fetching the page's HTML (the failing pass didn't hand any over).
    case fetching
    /// Reducing the HTML to a token-budgeted digest.
    case digesting
    /// Waiting on the model's plan.
    case thinking
    /// Waiting on the model's full-article payload (Private Cloud Compute only).
    case reading
    /// Applying the validated directive — the re-fetch / JavaScript run and the
    /// pipeline re-entry.
    case applying
    /// Done, whatever the outcome.
    case finished

    /// Where the bar sits when this stage BEGINS. A stage's own duration is
    /// covered by interpolating toward the next one's value.
    public var fraction: Double {
        switch self {
        case .queued: return 0.02
        case .replayingRule: return 0.08
        case .fetching: return 0.14
        case .digesting: return 0.26
        case .thinking: return 0.34
        case .reading: return 0.62
        case .applying: return 0.86
        case .finished: return 1.0
        }
    }

    /// Roughly how long this stage runs, used to creep the bar toward the next
    /// stage's fraction while waiting. Zero means "no creep" (instantaneous, or
    /// terminal).
    public var expectedDuration: TimeInterval {
        switch self {
        case .queued: return 0.5
        case .replayingRule: return 4
        case .fetching: return 6
        case .digesting: return 1.5
        case .thinking: return 22
        case .reading: return 22
        case .applying: return 8
        case .finished: return 0
        }
    }
}

public extension Notification.Name {
    /// Posted (on the main queue) whenever a rescue's stage advances. The item's
    /// `UUID` travels in `userInfo[RescueProgressKey.itemID]`.
    ///
    /// Separate from `.savesChanged` on purpose: progress fires many times
    /// per rescue, and `.savesChanged` makes every deck and list reload
    /// itself. This one only nudges the single card that's watching.
    static let rescueProgressChanged = Notification.Name("rescueProgressChanged")
}

/// `userInfo` keys for `.rescueProgressChanged`.
public enum RescueProgressKey {
    public static let itemID = "itemID"
}
