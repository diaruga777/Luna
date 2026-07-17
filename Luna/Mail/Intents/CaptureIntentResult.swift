//
//  CaptureIntentResult.swift
//  Luna
//
//  Transient result values for the two-step Action Button shortcut.
//

import AppIntents
import Foundation

enum ProvideContextOutcome: String, AppEnum {
    case done
    case unhandled
    case requiresScreenshot

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Outcome"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .done: "Done",
        .unhandled: "Unhandled",
        .requiresScreenshot: "Requires Screenshot",
    ]
}

struct ProvideContextResultEntity: TransientAppEntity {
    @Property(title: "Outcome") var outcome: ProvideContextOutcome
    @Property(title: "Media") var media: IntentFile?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Context Result"

    var displayRepresentation: DisplayRepresentation {
        switch outcome {
        case .done: return "Done"
        case .unhandled: return "Unhandled"
        case .requiresScreenshot: return "Requires Screenshot"
        }
    }

    init() {
        outcome = .unhandled
        media = nil
    }

    init(outcome: ProvideContextOutcome, media: IntentFile? = nil) {
        self.outcome = outcome
        self.media = media
    }
}

struct SaveResultEntity: TransientAppEntity {
    @Property(title: "Media") var media: IntentFile?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Save Result"
    var displayRepresentation: DisplayRepresentation { "Saved to Luna" }

    init() {
        media = nil
    }

    init(media: IntentFile? = nil) {
        self.media = media
    }
}
