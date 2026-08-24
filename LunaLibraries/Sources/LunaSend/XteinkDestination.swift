//
//  XteinkDestination.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage

/// The Xteink destination: enqueue-only. A send never waits for or probes for
/// a rendezvous — it attempts delivery immediately over whichever BLE/Wi-Fi
/// transport `XteinkCrossPointTransferRouter.send` is already active, and
/// throws `SendDeferralError` the instant no rendezvous exists so the item
/// stays queued at no retry cost. Actual delivery happens only when the
/// reader opens a window and Luna's `.xteinkRendezvousReady` sweep runs.
public final class XteinkDestination: ArticleDestination {
    public let id = ArticleDestinationID.xteink
    public let displayName = L10n.string("Common_xteink")

    private let crossPoint: XteinkCrossPointTransferRouter
    private let rendezvousQueue: XteinkRendezvousTransferQueue

    public init(
        crossPoint: XteinkCrossPointTransferRouter = XteinkCrossPointTransferRouter(),
        rendezvousQueue: XteinkRendezvousTransferQueue = .shared
    ) {
        self.crossPoint = crossPoint
        self.rendezvousQueue = rendezvousQueue
    }

    public var isConfigured: Bool { XteinkSendSettings.isConfigured }

    public func sendMode(for item: SavedItem) -> ArticleSendMode {
        SourceSendSettings.sendMode(
            forDestination: id, source: item.effectiveCaptureSource,
            friendUsername: item.sharedByUsername)
    }

    public var appIntentsSendMode: ArticleSendMode {
        SourceSendSettings.appIntentsMode(forDestination: id)
    }

    public func send(epubData: Data, fileName: String, title: String) async throws {
        try await send(epubData: epubData, fileName: fileName, title: title, articleID: nil, queuedRemaining: nil)
    }

    public func send(
        epubData: Data, fileName: String, title: String, context: ArticleSendContext
    ) async throws {
        try await send(
            epubData: epubData, fileName: fileName, title: title,
            articleID: context.itemID, queuedRemaining: context.queuedRemaining)
        // The exact sanitized basename the router put on the wire, recorded
        // so a later in-app read can target the same remote file for
        // removal (see `XteinkRemoteDeleteRunner`).
        SavesStore.shared.recordRemoteDelivery(
            for: context.itemID, destination: id,
            remoteName: XteinkCrossPointTransferRouter.x3FileName(fileName))
    }

    private func send(
        epubData: Data, fileName: String, title: String, articleID: UUID?, queuedRemaining: Int?
    ) async throws {
        do {
            let router = crossPoint
            try await rendezvousQueue.run {
                try await router.send(
                    epubData, fileName: fileName, title: title,
                    articleID: articleID, queuedRemaining: queuedRemaining)
            }
            SharedDiagnosticLog.record("Delivered \(fileName)", category: "xteink")
        } catch XteinkSyncError.unavailable {
            // No live rendezvous is not a failed delivery. Keep the item
            // queued so the reader's next Luna Sync window can collect it.
            SharedDiagnosticLog.record(
                "\(fileName) queued — no rendezvous active", category: "xteink")
            throw XteinkRendezvousUnavailableError()
        } catch XteinkSyncError.pairingRequired {
            // Enabled but not (yet) paired on this device. Not a failure
            // either: pairing is the missing setup step, not a broken send,
            // so the item waits queued at no retry cost.
            SharedDiagnosticLog.record(
                "Send deferred: no pairing secret on this device", category: "xteink")
            throw XteinkRendezvousUnavailableError()
        } catch XteinkSyncError.protocolError(let message) where message == "exists" {
            // The reader refuses to overwrite a file already in /Books — the
            // book IS on the device (an earlier delivery Luna failed to
            // record, or a deliberate re-send). Retrying can never succeed,
            // so count it delivered.
            SharedDiagnosticLog.record(
                "\(fileName) already on the reader — recorded as delivered", category: "xteink")
        } catch {
            SharedDiagnosticLog.record("Send of \(fileName) failed: \(error)", category: "xteink")
            throw error
        }
    }
}

/// One X3 accepts one control operation / data stream at a time. The article
/// coordinator intentionally fans pending sends out concurrently, so this
/// gate is mandatory rather than an optimization.
public actor XteinkRendezvousTransferQueue {
    public static let shared = XteinkRendezvousTransferQueue()
    private var tail: Task<Void, Never>?
    public init() {}

    public func run<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task<Result<T, Error>, Never> {
            await previous?.value
            do { return .success(try await operation()) }
            catch { return .failure(error) }
        }
        tail = Task { _ = await work.value }
        return try await work.value.get()
    }
}

public struct XteinkRendezvousUnavailableError: Error, SendDeferralError {
    public init() {}
}
