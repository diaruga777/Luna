//
//  AIWritingAssisting.swift
//  LunaWriterEditor
//

import Foundation

/// On-device writing help. Everything it returns lands in the sheet as an
/// `.ai` authorship span, so the writer can always see which words are not
/// theirs.
public protocol AIWritingAssisting: AnyObject {
    /// Recorded on the spans this assistant produces.
    var modelIdentifier: String { get }
    /// Whether the model can answer on this device right now.
    var isAvailable: Bool { get }
    func continueWriting(context: String) async throws -> String
    func rewrite(_ text: String, instruction: String?) async throws -> String
}
