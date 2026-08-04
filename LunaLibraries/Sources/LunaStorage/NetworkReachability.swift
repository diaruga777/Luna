//
//  NetworkReachability.swift
//  LunaStorage
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

    /// Posted when the path transitions from NOT-on-Wi-Fi to on-Wi-Fi, so
    /// features deferred while off Wi-Fi (Downloader's Wi-Fi-only downloads,
    /// Reader's Wi-Fi-only preload) can resume immediately instead of waiting
    /// for the next foreground/background-task. Posted on the monitor's own
    /// background queue, not main.
    public static let wifiAvailableNotification = Notification.Name("NetworkReachability.wifiAvailable")

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasOnWiFi = self.isOnWiFi
            self.lock.lock(); self.path = path; self.lock.unlock()
            if !wasOnWiFi, self.isOnWiFi {
                NotificationCenter.default.post(name: Self.wifiAvailableNotification, object: nil)
            }
        }
        monitor.start(queue: DispatchQueue(label: "inc.putty.clip.reachability"))
    }

    /// True when there is any usable route off the device — Wi-Fi, cellular,
    /// wired, anything. The question `isOnWiFi` does not answer: a background
    /// crawl should defer off Wi-Fi, but a USER-initiated load happily runs on
    /// cellular and only "no connection at all" changes what it should do.
    ///
    /// Optimistic before the first path update, deliberately, and the opposite
    /// of `isOnWiFi`'s pessimism for the same reason: this gates a load the user
    /// asked for. Guessing "offline" would show an error page instead of
    /// attempting a fetch that would have worked; guessing "online" attempts the
    /// fetch, and if it really is offline the fetch fails into the same real
    /// error state a moment later.
    public var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let path else { return true }
        return path.status == .satisfied
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
