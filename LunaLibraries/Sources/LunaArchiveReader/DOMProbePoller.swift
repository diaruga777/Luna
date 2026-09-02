//
//  DOMProbePoller.swift
//  LunaArchiveReader
//

import Foundation
import UIKit
import WebKit

/// Evaluates a probe script in a live page and answers its string result.
///
/// A seam rather than a `WKWebView` parameter: a challenge flow's stage machine
/// is the part worth testing, and driving it needs a scripted sequence of
/// answers, not a real WebContent process.
public protocol DOMProbeEvaluating: AnyObject {
    /// Runs `source` in the page's main world. `nil` for a page that answered
    /// nothing readable.
    func evaluateProbe(_ source: String, completion: @escaping (String?) -> Void)
}

extension WKWebView: DOMProbeEvaluating {
    public func evaluateProbe(_ source: String, completion: @escaping (String?) -> Void) {
        evaluateJavaScript(source) { result, _ in
            completion(result as? String)
        }
    }
}

/// Who the poller tells that another interval has passed.
public protocol DOMProbePollerDelegate: AnyObject {
    func probePollerDidTick(_ poller: DOMProbePoller)
}

/// The repeating tick a challenge flow re-reads its page on.
///
/// A page can change stage without a navigation — a CAPTCHA clears in place, a
/// SPA hydrates — so `didFinish` alone misses it. The interval is short enough
/// that a solved challenge is noticed as it happens and long enough that a whole
/// unlock costs a few hundred evaluations.
public final class DOMProbePoller {

    /// The shipped interval. Every challenge flow polls at the same rate.
    public static let interval: TimeInterval = 0.35

    public weak var delegate: DOMProbePollerDelegate?

    private let interval: TimeInterval
    private var timer: Timer?

    public init(interval: TimeInterval = DOMProbePoller.interval) {
        self.interval = interval
    }

    public var isRunning: Bool { timer != nil }

    /// Restarts the tick. Calling it twice leaves one timer.
    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.delegate?.probePollerDidTick(self)
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One tick, now. The flow's own `didFinish` uses it, and so does a test
    /// that drives the stage machine without a run loop.
    public func tickNow() {
        delegate?.probePollerDidTick(self)
    }

    deinit { timer?.invalidate() }
}

/// The mobile-Safari User-Agent that matches THIS device's iOS version.
///
/// A stale or hardcoded version is a UA/OS mismatch, which Cloudflare's bot
/// check reads as an automated client and re-challenges forever; real Safari is
/// consistent and passes. Every challenge flow presents this one.
public enum DeviceSafariUserAgent {

    public static var current: String {
        let version = UIDevice.current.systemVersion                       // e.g. "27.0"
        let osToken = version.replacingOccurrences(of: ".", with: "_")     // "27_0"
        let major = version.split(separator: ".").first.map(String.init) ?? version
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }
}
