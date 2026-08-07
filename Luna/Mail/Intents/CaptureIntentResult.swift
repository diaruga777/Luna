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

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intents_provideContextOutcome_typeName_Luna"
    // AppEnum metadata, extracted at BUILD time — same restriction as
    // `typeDisplayRepresentation`: the title must be a string literal, so it
    // can't go through `L10n.resource(...)` the way the per-instance
    // `displayRepresentation` below does.
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .done: "Intents_provideContextOutcome_doneCase_title_Luna",
        .screenshot: "Intents_provideContextOutcome_screenshotCase_title_Luna",
        .download: "Intents_provideContextOutcome_downloadCase_title_Luna",
        .unhandled: "Intents_provideContextOutcome_unhandledCase_title_Luna",
    ]
}

struct ProvideContextResultEntity: TransientAppEntity {
    @Property(title: "Intents_provideContextResultEntity_mediaProperty_title_Luna") var media: IntentFile?
    @Property(title: "Intents_provideContextResultEntity_outcomeProperty_title_Luna") var outcome: ProvideContextOutcome
    @Property(title: "Intents_provideContextResultEntity_metadataProperty_title_Luna") var metadata: String?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intents_provideContextResultEntity_typeName_Luna"

    var displayRepresentation: DisplayRepresentation {
        switch outcome {
        case .done: return DisplayRepresentation(title: L10n.resource("Intents_provideContextOutcome_doneCase_title"))
        case .screenshot: return DisplayRepresentation(title: L10n.resource("Intents_provideContextOutcome_screenshotCase_title"))
        case .download: return DisplayRepresentation(title: L10n.resource("Intents_provideContextOutcome_downloadCase_title"))
        case .unhandled: return DisplayRepresentation(title: L10n.resource("Intents_provideContextOutcome_unhandledCase_title"))
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
    @Property(title: "Intents_saveResultEntity_mediaProperty_title_Luna") var media: IntentFile?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intents_saveResultEntity_typeName_Luna"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: L10n.resource("Common_savedToLuna"))
    }

    init() {
        media = nil
    }

    init(media: IntentFile? = nil) {
        self.media = media
    }
}
