//
//  RescueTraceStore.swift
//  LunaURLRescue
//

import Foundation
import LunaStorage

/// The engine's view of the per-save diagnostic trace: read it as failure
/// EVIDENCE for the model, and write each rescue's own decisions back into it so
/// the file the user exports from a failed card explains the rescue too.
///
/// A protocol rather than a direct `SaveDiagnosticsStore` reference so the whole
/// evidence/trace path is testable with a fake — the real store is App-Group
/// backed, and on a fresh failure `contents(for:)` legitimately returns nil, so
/// BOTH cases have to be exercised.
public protocol RescueTraceStoring: AnyObject {
    func contents(for itemID: UUID) -> String?
    func appendLine(_ line: String, for itemID: UUID)
}

extension SaveDiagnosticsStore: RescueTraceStoring {}

/// Stands in when no item id is known (the price editor's ad-hoc resolution, the
/// media card) or when a caller deliberately runs trace-less.
public final class NoRescueTraceStore: RescueTraceStoring {
    public init() {}
    public func contents(for itemID: UUID) -> String? { nil }
    public func appendLine(_ line: String, for itemID: UUID) {}
}
