//
//  XteinkDestination.swift
//  Luna
//

import Foundation
import LunaModels

/// The Xteink destination: delivers over the CrossPoint BLE rendezvous, or
/// straight over Wi-Fi when the reader's File Transfer server is already
/// reachable (`XteinkCrossPointTransferRouter.sendNow`). The device is only
/// reachable while it's awake, so an unreachable device throws
/// `SendDeferralError` — the item stays queued at no retry cost and goes out
/// on a later sweep.
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
        do {
            let router = crossPoint
            try await rendezvousQueue.run {
                try await router.sendNow(epubData, fileName: fileName, title: title)
            }
        } catch XteinkSyncError.unavailable {
            // A sleep/wake rendezvous is not a failed delivery. Keep the item
            // queued so the X3's next power-button or timed wake can collect it.
            throw XteinkRendezvousUnavailableError()
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
