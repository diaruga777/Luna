//
//  SaveDiagnostics.swift
//  LunaModels
//

import Foundation

/// The in-memory half of the per-save diagnostic trace: everything the pipeline
/// observed while trying to save ONE URL, buffered under a correlation id so a
/// failure can flush a complete story and a success can throw it away.
///
/// This lives in LunaModels — the bottom of the stack — on purpose. The layers
/// worth instrumenting (LunaFetch, LunaPaywallBypass, LunaHTMLClassification,
/// LunaIngest, LunaMediaResolve, LunaPriceIngest) already depend on LunaModels
/// and NOT on LunaStorage, so recording here costs no new dependency edge and
/// keeps `LunaMediaResolve`/`LunaPriceCompare` on their Foundation-only floors.
/// The storage half — the per-item `saveDiagnostics/<UUID>.log` file — is
/// `SaveDiagnosticsStore` in LunaStorage, and only the two layers that own
/// persistence (`ReadingListIngestor`, `ShareSurfaceDriver`) ever touch it.
///
/// Instrumentation call sites are UNCONDITIONAL: they call
/// `SaveDiagnostics.record(…)`, which is a no-op (and does not even build its
/// message, thanks to the autoclosure) unless a save has bound a recorder to
/// the current task. So a preload, a metadata refresh, or the onboarding demo
/// runs the same code and writes nothing.
public final class SaveDiagnosticsRecorder: @unchecked Sendable {

    /// The reading-list item this trace belongs to — the correlation id.
    public let itemID: UUID

    /// Mirrors each recorded message to the general diagnostics stream
    /// (`clip-diagnostics.log`), so a live tail shows the save as it happens
    /// even when it ultimately succeeds and the buffer is dropped. Installed by
    /// the layer that owns storage: `DiagnosticLog.shared.record` in the app,
    /// `SharedDiagnosticLog.record` (synchronous) in an extension.
    private let mirror: @Sendable (String, String) -> Void

    /// One formatter per recorder: `ISO8601DateFormatter` is not safe to share
    /// across the threads a save's legs run on, and a recorder is bound to one
    /// save.
    private let formatter: ISO8601DateFormatter
    private let lock = NSLock()
    private var lines: [String] = []
    private var storedTerminalFailure: SaveFailureReason?

    /// A save that somehow loops would otherwise buffer without bound. Past the
    /// cap the OLDEST lines go (same priority as the on-disk trim: the end of
    /// the story is the part that explains the failure).
    private let maxBufferedLines: Int
    private var droppedLines = 0

    public init(
        itemID: UUID,
        maxBufferedLines: Int = 2_000,
        mirror: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) {
        self.itemID = itemID
        self.maxBufferedLines = maxBufferedLines
        self.mirror = mirror
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    /// The `[save <first 8 of the item UUID>]` prefix the general stream is
    /// tagged with — the `[category]` slot of a diagnostics line is already
    /// taken, so the correlation id rides the message.
    public var tag: String { "[save \(itemID.uuidString.prefix(8))]" }

    /// Buffers one timestamped `ISO8601 [category] message` line and mirrors the
    /// tagged message to the general stream. One `Date()` is taken per call and
    /// used for the buffered line; the mirror stamps its own copy microseconds
    /// later, which is why the two files interleave rather than match exactly.
    public func record(_ message: String, category: String) {
        let now = Date()
        lock.sync {
            // The formatter is guarded by the same lock as the buffer:
            // ISO8601DateFormatter is not safe to use from two threads, and a
            // save's legs record from several.
            lines.append("\(formatter.string(from: now)) [\(category)] \(message)")
            if lines.count > maxBufferedLines {
                droppedLines += lines.count - maxBufferedLines
                lines.removeFirst(lines.count - maxBufferedLines)
            }
        }
        mirror("\(tag) \(message)", category)
    }

    /// The buffered lines, emptying the buffer — the failure-time flush. A
    /// trimmed buffer says so in its first line so a shared trace never looks
    /// complete when it isn't.
    public func drainLines() -> [String] {
        lock.sync {
            var drained = lines
            if droppedLines > 0 {
                drained.insert("…(\(droppedLines) earlier lines dropped)", at: 0)
            }
            lines.removeAll()
            droppedLines = 0
            return drained
        }
    }

    /// Whether anything has been recorded (without consuming it).
    public var isEmpty: Bool { lock.sync { lines.isEmpty } }

    /// Set when a leg of the save decided the save is terminally broken even
    /// though the pipeline's own `Outcome` was a success — the media case: a
    /// post classifies fine as `.video`, is stored, and only the download that
    /// follows discovers there is no asset behind it. Without this the trace of
    /// a save that visibly did not work would be dropped as a success.
    public var terminalFailure: SaveFailureReason? { lock.sync { storedTerminalFailure } }

    public func markTerminalFailure(_ reason: SaveFailureReason) {
        lock.sync { storedTerminalFailure = reason }
    }
}

/// The ambient binding. `@TaskLocal` because a save is one structured async
/// call tree: bind once around the pipeline call and every leg inside it — the
/// fetcher, the bypass runner, the classifier, the media resolver — records
/// into the right trace with no argument threading.
public enum SaveDiagnostics {

    /// The recorder for the save running on this task, if any.
    @TaskLocal public static var recorder: SaveDiagnosticsRecorder?

    /// Records one line into the in-flight save's trace. A no-op outside a save
    /// — and the `@autoclosure` means the message is never even built there, so
    /// instrumenting a hot path costs nothing when nothing is listening.
    ///
    /// **Never pass a response body.** Shapes, sizes, statuses and decisions
    /// only; cap any quoted snippet at ~200 chars (`snippet(_:)`).
    public static func record(_ message: @autoclosure () -> String, category: String) {
        guard let recorder else { return }
        recorder.record(message(), category: category)
    }

    /// Whether a save is being traced right now — for the rare call site that
    /// wants to skip expensive *gathering* (not just string building).
    public static var isRecording: Bool { recorder != nil }

    /// Tells the in-flight save's trace that the save is broken even though the
    /// pipeline is about to report a success `Outcome`, so the flush keeps the
    /// buffer instead of dropping it. The ONE caller today is the media leg
    /// (a post that classifies but resolves no asset). No-op outside a save.
    public static func markTerminalFailure(_ reason: SaveFailureReason) {
        recorder?.markTerminalFailure(reason)
    }

    /// One trace line in the on-disk format, for the rare writer that has no
    /// recorder to buffer into and appends to `SaveDiagnosticsStore` directly —
    /// a background transfer that fails long after the save's task tree is
    /// gone, or a rescue attempt appending its own leg.
    public static func formatLine(
        _ message: String, category: String, date: Date = Date()
    ) -> String {
        let stamp = formatterLock.sync { sharedFormatter.string(from: date) }
        return "\(stamp) [\(category)] \(message)"
    }

    /// Serialized behind its own lock: `ISO8601DateFormatter` is not
    /// thread-safe, and `formatLine` is called from background delegate queues.
    private static let formatterLock = NSLock()
    private static let sharedFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Runs `body` with `recorder` bound. The explicit form exists so a caller
    /// that already has a recorder doesn't have to reach for `$recorder`.
    public static func withRecorder<T>(
        _ recorder: SaveDiagnosticsRecorder?, operation body: () async throws -> T
    ) async rethrows -> T {
        try await $recorder.withValue(recorder, operation: body)
    }

    /// Clamps a quoted fragment (an error string, a title, a page snippet) to a
    /// safe length for the trace, collapsing newlines so one record stays one
    /// line.
    public static func snippet(_ text: String, limit: Int = 200) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    /// A URL clamped for the trace. Kept WHOLE (query included): a save that
    /// failed often failed *because* of a parameter, and the item's URL is in
    /// the export header verbatim anyway — stripping it here would lose signal
    /// without buying any privacy.
    public static func url(_ url: URL) -> String {
        snippet(url.absoluteString)
    }
}

private extension NSLock {
    /// Deliberately not named `withLock`: Foundation ships its own
    /// `NSLocking.withLock`, and a same-file private overload of it is
    /// ambiguous rather than shadowing.
    func sync<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
