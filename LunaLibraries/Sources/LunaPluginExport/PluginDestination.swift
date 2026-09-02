//
//  PluginDestination.swift
//  LunaPluginExport
//

import Foundation
import LunaEpub
import LunaModels
import LunaPluginKit
import LunaSend

/// A delivery that failed. `hard` failures are terminal — the coordinator
/// stops retrying and the save shows the message.
public enum PluginDestinationError: Error, CustomStringConvertible {
    /// The plugin asked for another attempt.
    case retry(String?)
    /// The plugin reported a failure this attempt only.
    case soft(String)
    /// The plugin reported a failure that will not change.
    case hard(String)
    /// A plugin destination delivers a SAVE; loose EPUB bytes have no save to
    /// build an input from.
    case unsupportedPayload

    public var description: String {
        switch self {
        case .retry(let message): return message ?? "the plugin asked to retry"
        case .soft(let message), .hard(let message): return message
        case .unsupportedPayload:
            return "this destination delivers a save, not loose EPUB bytes"
        }
    }
}

extension PluginDestinationError: SendHardFailureError {
    /// Only the terminal cases are hard. `SendHardFailureError` is a marker, so
    /// the coordinator asks this.
    public var isHardSendFailure: Bool {
        switch self {
        case .hard, .unsupportedPayload: return true
        case .retry, .soft: return false
        }
    }
}

/// One export plugin that declared itself a destination
/// (`claudedocs/plans/plugin-platform.md` §9.4).
///
/// Everything the coordinator does around the delivery — gating, queueing,
/// backoff, per-source auto-send, the double-save press — is unchanged: this
/// only replaces the delivery itself, and it keeps the destination id so the
/// bookkeeping already in the store keeps applying.
public final class PluginDestination: ArticleDestination {

    public let pluginID: String
    private let export: PluginExportSummary
    private let stage: PluginExportStage?

    public init(
        pluginID: String, export: PluginExportSummary, stage: PluginExportStage? = nil
    ) {
        self.pluginID = pluginID
        self.export = export
        self.stage = stage
    }

    public var id: String { PluginDestinationLegacyIDs.destinationID(forPluginID: pluginID) }

    public var displayName: String { export.title }

    public var isConfigured: Bool {
        PluginExportConfiguration.isConfigured(pluginID: pluginID, export: export)
    }

    public func sendMode(for item: SavedItem) -> ArticleSendMode {
        SourceSendSettings.sendMode(
            forDestination: id, source: item.effectiveCaptureSource,
            friendUsername: item.sharedByUsername)
    }

    public var appIntentsSendMode: ArticleSendMode {
        SourceSendSettings.appIntentsMode(forDestination: id)
    }

    /// Declared by the plugin: its receiver tracks reading of its own, so a
    /// save finished in Luna before delivery is dropped from the queue.
    public var dequeuesOnRead: Bool { export.dequeueOnRead }

    /// The share row comes from the plugin's own declaration, through
    /// `PluginExportSeams.rows`.
    public var providesOwnShareRow: Bool { true }

    public var epubBuildProfile: EpubBuilder.Profile {
        PluginExportInputProducer.epubProfile(export)
    }

    /// The coordinator calls `deliver`; this is only reachable through
    /// `sendTestDocument`, which has no save to export.
    public func send(epubData: Data, fileName: String, title: String) async throws {
        throw PluginDestinationError.unsupportedPayload
    }

    /// Runs the plugin's export hook for this save and maps its answer onto the
    /// coordinator's send states.
    public func deliver(item: SavedItem, context: ArticleSendContext) async throws {
        let stage = await resolvedStage()
        let outcome = await stage.run(
            pluginID: pluginID, saveID: item.id, auto: true,
            queuedRemaining: context.queuedRemaining)
        switch outcome {
        case .handled, .presented:
            return
        case .status(.sent, _, _):
            return
        case .status(.retry, let message, _):
            throw PluginDestinationError.retry(message)
        case .status(.failed, let message, let hard):
            let text = message ?? "\(displayName) reported a failure"
            throw hard
                ? PluginDestinationError.hard(text)
                : PluginDestinationError.soft(text)
        case .failed(let message, let hard):
            throw hard
                ? PluginDestinationError.hard(message)
                : PluginDestinationError.soft(message)
        }
    }

    @MainActor
    private func resolvedStage() -> PluginExportStage {
        stage ?? PluginExportStage.shared
    }
}
