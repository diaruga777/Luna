//
//  ReadAlongTicker.swift
//  LunaWriterReadAlong
//

import Foundation
import QuartzCore

/// The reader of a ticker's frames.
public protocol ReadAlongTickReceiving: AnyObject {
    /// One frame, at `time` on the ticker's own clock.
    func readAlongDidTick(at time: TimeInterval)
}

/// A frame clock. Production is a `CADisplayLink`; a test drives its own.
public protocol ReadAlongTicking: AnyObject {
    var target: ReadAlongTickReceiving? { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
}

/// A clock read once per gaze sample. The tracker's own timestamps are not
/// available through `GazeTracking`, so the coordinator stamps samples itself.
public protocol ReadAlongClock: AnyObject {
    var now: TimeInterval { get }
}

public final class SystemReadAlongClock: ReadAlongClock {
    public init() {}
    public var now: TimeInterval { CACurrentMediaTime() }
}

/// The production ticker.
public final class DisplayLinkTicker: NSObject, ReadAlongTicking {

    public weak var target: ReadAlongTickReceiving?
    public private(set) var isRunning = false

    private var link: CADisplayLink?

    public override init() {
        super.init()
    }

    deinit {
        link?.invalidate()
    }

    public func start() {
        guard !isRunning else { return }
        let link = CADisplayLink(target: LinkProxy(ticker: self), selector: #selector(LinkProxy.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        isRunning = true
    }

    public func stop() {
        link?.invalidate()
        link = nil
        isRunning = false
    }

    fileprivate func fire(_ link: CADisplayLink) {
        target?.readAlongDidTick(at: link.timestamp)
    }

    /// `CADisplayLink` retains its target. Pointing it at this proxy instead
    /// of the ticker lets a ticker nobody holds any more deallocate, and its
    /// `deinit` then invalidates the link.
    private final class LinkProxy: NSObject {
        weak var ticker: DisplayLinkTicker?
        init(ticker: DisplayLinkTicker) { self.ticker = ticker }
        @objc func fire(_ link: CADisplayLink) { ticker?.fire(link) }
    }
}
