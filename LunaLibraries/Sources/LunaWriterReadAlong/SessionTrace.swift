//
//  SessionTrace.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaGaze

/// One decimated frame of a read-along session.
public struct SessionTraceSample: Codable, Equatable {
    public let time: TimeInterval
    /// The calibrated gaze in text-container coordinates, when there was one.
    public let gazeX: Double?
    public let gazeY: Double?
    public let gate: String
    public let sentence: Int?
    public let cursorWord: Int?
    public let mode: String
    public let quality: Double
    public let residual: Double

    public init(
        time: TimeInterval, gaze: CGPoint?, gate: GateReason, state: ReadingState
    ) {
        self.time = time
        self.gazeX = gaze.map { Double($0.x) }
        self.gazeY = gaze.map { Double($0.y) }
        self.gate = gate.rawValue
        self.sentence = state.activeSentence
        self.cursorWord = state.cursorWord
        self.mode = state.mode.rawValue
        self.quality = state.quality
        self.residual = Double(state.residual)
    }
}

/// A ring buffer of the session, for the diagnostics export.
///
/// It is decimated to 10 Hz and capped, so a long session costs a bounded
/// amount of memory and the oldest frames fall off rather than the newest
/// being refused.
public final class SessionTrace {

    /// Frames kept: 6000 at 10 Hz is ten minutes.
    public static let capacity = 6000
    /// Shortest gap between kept frames.
    public let minimumInterval: TimeInterval

    private var buffer: [SessionTraceSample] = []
    private var head = 0
    private var lastKept: TimeInterval?
    private let limit: Int

    public init(capacity: Int = SessionTrace.capacity, minimumInterval: TimeInterval = 0.1) {
        self.limit = max(1, capacity)
        self.minimumInterval = minimumInterval
        buffer.reserveCapacity(min(self.limit, 1024))
    }

    /// Offers one frame. Returns true when it was kept.
    @discardableResult
    public func record(
        at time: TimeInterval, gaze: CGPoint?, gate: GateReason, state: ReadingState
    ) -> Bool {
        if let lastKept, time - lastKept < minimumInterval { return false }
        lastKept = time
        let sample = SessionTraceSample(time: time, gaze: gaze, gate: gate, state: state)
        if buffer.count < limit {
            buffer.append(sample)
        } else {
            buffer[head] = sample
            head = (head + 1) % limit
        }
        return true
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        head = 0
        lastKept = nil
    }

    /// The kept frames, oldest first.
    public var samples: [SessionTraceSample] {
        guard buffer.count == limit, head > 0 else { return buffer }
        return Array(buffer[head...] + buffer[..<head])
    }

    public var count: Int { buffer.count }

    /// The trace as JSON, for the share sheet.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(samples)
    }

    /// Writes the trace to a temporary file and returns its URL, so the share
    /// sheet offers a named document rather than a blob of text.
    public func writeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("luna-read-along-\(Int(Date().timeIntervalSince1970)).json")
        try jsonData().write(to: url, options: .atomic)
        return url
    }
}
