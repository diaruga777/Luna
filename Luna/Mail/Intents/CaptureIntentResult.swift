//
//  CaptureIntentResult.swift
//  Luna
//
//  Transient result values for the two-step Action Button shortcut.
//

import AppIntents
import Foundation
import LunaModels

enum ProvideContextOutcome: String, AppEnum {
    case done
    case screenshot
    case download
    case unhandled

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Outcome"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .done: "Done",
        .screenshot: "Screenshot",
        .download: "Download",
        .unhandled: "Unhandled",
    ]
}

struct ProvideContextResultEntity: TransientAppEntity {
    @Property(title: "Media") var media: IntentFile?
    @Property(title: "Outcome") var outcome: ProvideContextOutcome
    @Property(title: "Metadata") var metadata: String?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Context Result"

    var displayRepresentation: DisplayRepresentation {
        switch outcome {
        case .done: return DisplayRepresentation(title: L10n.resource("Done"))
        case .screenshot: return DisplayRepresentation(title: L10n.resource("Screenshot"))
        case .download: return DisplayRepresentation(title: L10n.resource("Download"))
        case .unhandled: return DisplayRepresentation(title: L10n.resource("Unhandled"))
        }
    }

    init() {
        outcome = .unhandled
        media = nil
        metadata = nil
    }

    init(
        outcome: ProvideContextOutcome,
        media: IntentFile? = nil,
        metadata: String? = nil
    ) {
        self.outcome = outcome
        switch outcome {
        case .done:
            self.media = media
            self.metadata = nil
        case .screenshot, .download:
            self.media = nil
            self.metadata = metadata
        case .unhandled:
            self.media = nil
            self.metadata = nil
        }
    }
}

struct SaveResultEntity: TransientAppEntity {
    @Property(title: "Media") var media: IntentFile?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Save Result"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: L10n.resource("Saved to Luna"))
    }

    init() {
        media = nil
    }

    init(media: IntentFile? = nil) {
        self.media = media
    }
}
