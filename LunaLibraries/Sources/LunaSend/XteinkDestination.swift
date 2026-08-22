//
//  XteinkDestination.swift
//  Luna
//

import Foundation
import LunaModels

/// The Xteink destination: a direct HTTP upload to the e-reader's Wi-Fi file
/// manager. The device only serves while awake on its Cloud / App Connect
/// screen, so an unreachable device throws `SendDeferralError` — the item
/// stays queued at no retry cost and goes out on a later sweep.
public final class XteinkDestination: ArticleDestination {
    public let id = ArticleDestinationID.xteink
    public let displayName = L10n.string("Common_xteink")

    private let client: XteinkDeviceClient
    private let queue: XteinkTransferQueue
    private let crossPoint: XteinkCrossPointTransferRouter

    public init(
        client: XteinkDeviceClient = XteinkDeviceClient(),
        queue: XteinkTransferQueue = .shared,
        crossPoint: XteinkCrossPointTransferRouter = XteinkCrossPointTransferRouter()
    ) {
        self.client = client
        self.queue = queue
        self.crossPoint = crossPoint
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
            try await crossPoint.send(epubData, fileName: fileName, title: title)
        } catch XteinkSyncError.unavailable {
            // A sleep/wake rendezvous is not a failed delivery. Keep the item
            // queued so the X3's next power-button or timed wake can collect it.
            throw XteinkRendezvousUnavailableError()
        }
    }
}

public struct XteinkRendezvousUnavailableError: Error, SendDeferralError {
    public init() {}
}

/// Serializes transfers and shares one reachability probe across them. The
/// coordinator fans a sweep out as one concurrent task per queued item; an
/// ESP32 cannot take parallel uploads, and with the device asleep a sweep of N
/// items must cost one probe, not N.
public actor XteinkTransferQueue {

    public static let shared = XteinkTransferQueue()

    /// How long one probe answer stands for the transfers behind it in line.
    private static let probeLifetime: TimeInterval = 10

    private var tail: Task<Void, Never>?
    private var lastProbe: (date: Date, host: String?)?
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Runs `operation` against the reachable device, after every transfer
    /// already in line. Throws `XteinkDeviceClient.UnreachableError` when no
    /// candidate host answers.
    public func run<T: Sendable>(
        client: XteinkDeviceClient,
        hosts: [String],
        _ operation: @Sendable @escaping (String) async throws -> T
    ) async throws -> T {
        let previous = tail
        let work = Task<Result<T, Error>, Never> {
            await previous?.value
            guard let host = await self.reachableHost(client: client, hosts: hosts) else {
                return .failure(XteinkDeviceClient.UnreachableError())
            }
            do {
                return .success(try await operation(host))
            } catch let error as XteinkDeviceClient.UnreachableError {
                // The device dropped off mid-transfer: the cached probe is stale.
                await self.forgetProbe()
                return .failure(error)
            } catch {
                return .failure(error)
            }
        }
        tail = Task { _ = await work.value }
        return try await work.value.get()
    }

    private func reachableHost(client: XteinkDeviceClient, hosts: [String]) async -> String? {
        if let lastProbe, now().timeIntervalSince(lastProbe.date) < Self.probeLifetime {
            return lastProbe.host
        }
        let host = await client.findDevice(among: hosts)
        lastProbe = (now(), host)
        return host
    }

    private func forgetProbe() {
        lastProbe = nil
    }
}
