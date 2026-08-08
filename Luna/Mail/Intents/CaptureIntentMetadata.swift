//
//  CaptureIntentMetadata.swift
//  Luna
//
//  Versioned opaque state passed from Provide Context to Save by Shortcuts.
//

import LunaIntents
import LunaModels
import Foundation

/// A resolved media preflight. Carrying the direct asset and verified byte count
/// lets SaveIntent begin the actual transfer with real progress immediately,
/// without repeating resolver, redirect, or HEAD work from Provide Context.
struct IntentMediaCheckpoint: Codable, Equatable {
    let asset: MediaAsset
    let expectedByteCount: Int64?
}

/// The resumable capture state encoded into the result entity's opaque Metadata
/// string. The schema is deliberately additive: a newer producer may add fields,
/// while an older/invalid value simply makes Save run from the top.
struct CaptureIntentMetadata: Codable, Equatable {
    enum Phase: String, Codable {
        /// Save/ingest work was prepared but did not finish inside the fast path.
        case save
        /// The URL is saved; only media preflight/download work remains.
        case download
        /// Save still needs the screenshot analysis route to resolve a URL.
        case screenshot
        /// The product is saved and its alternative sellers are attached; only
        /// the comparison SUMMARY remains — refreshing day-old seller prices and
        /// rendering the document (`claudedocs/price-comparison.md`). Added in
        /// schema v2.
        case comparison
    }

    /// v2 added `Phase.comparison`. Purely additive: a v1 value carries no new
    /// field and no new case, so it still decodes — see `decode`.
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var phase: Phase
    var currentApp: String?
    var resolvedURLString: String?
    var isDoubleSave: Bool?
    var preparedSave: IntentIngestHelper.PreparedSavePress?
    var media: IntentMediaCheckpoint?

    init(
        phase: Phase,
        currentApp: String?,
        resolvedURLString: String? = nil,
        isDoubleSave: Bool? = nil,
        preparedSave: IntentIngestHelper.PreparedSavePress? = nil,
        media: IntentMediaCheckpoint? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.phase = phase
        self.currentApp = currentApp
        self.resolvedURLString = resolvedURLString
        self.isDoubleSave = isDoubleSave
        self.preparedSave = preparedSave
        self.media = media
    }

    var opaqueString: String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String?) -> Self? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Every schema up to the current one is accepted, because the schema is
        // additive by rule: a v1 checkpoint held in a Shortcut across an app
        // update describes a save that is genuinely still resumable, and
        // rejecting it would silently restart work the user already waited for.
        // A value from a FUTURE version is refused — its phase may be one this
        // build cannot perform.
        guard let value = try? decoder.decode(Self.self, from: data),
              (1...currentSchemaVersion).contains(value.schemaVersion)
        else { return nil }
        return value
    }
}

enum CaptureIntentFastPathError: Error {
    case timedOut
}

private final class CaptureIntentFastPathState<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<T, Error>

    init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        if first { continuation.resume(with: result) }
        return first
    }
}

/// A timeout race that returns at the deadline instead of waiting for the losing
/// child (Swift task groups wait for every child when their scope exits). The
/// work task is cancelled immediately; the resumable save placeholder remains
/// durable while the losing task cooperatively unwinds.
enum CaptureIntentFastPath {
    static func run<T>(
        timeout: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            let state = CaptureIntentFastPathState(continuation: continuation)
            let work = Task {
                do { state.finish(.success(try await operation())) }
                catch { state.finish(.failure(error)) }
            }
            Task {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                } catch { return }
                if state.finish(.failure(CaptureIntentFastPathError.timedOut)) {
                    work.cancel()
                }
            }
        }
    }
}
