//
//  NetworkReachability.swift
//  LuneStorage
//

import Foundation
import Network

/// A lightweight, always-on snapshot of the current network path, used to gate
/// **background/speculative** preloading to Wi-Fi (the user's chosen policy for
/// durable offline downloads, which can be large). User-initiated loads — opening
/// or tapping a page — never consult this; they load on any network.
///
/// `NWPathMonitor` reports the path asynchronously, so `isOnWiFi` is a best-effort
/// snapshot: before the first update arrives it returns `false` (conservative — we'd
/// rather defer a background crawl and resume it on the next foreground than spend
/// cellular data). Warm it at launch (touch `.shared`) so the path is known well
/// before any save happens.
public final class NetworkReachability {
    public static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.path = path; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "inc.putty.clip.reachability"))
    }

    /// True only when connected over Wi-Fi (or wired Ethernet, e.g. a simulator) and
    /// NOT over cellular. `false` until the first path update.
    public var isOnWiFi: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let path, path.status == .satisfied else { return false }
        if path.usesInterfaceType(.cellular) { return false }
        return path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
    }
}
