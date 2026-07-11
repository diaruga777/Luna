//
//  SaveResponseParsing.swift
//  LunaIntents
//

import Foundation

/// Splits the on-device model's single response string (produced from a screen
/// prompt — see `AppNamePlatform.screenPrompt`/`safariScreenPrompt`) into its
/// " ; "-joined fields. Relocated verbatim from `SaveFromAppIntent.parseFields`.
public enum SaveResponseParsing {

    /// Splits the model's single response string into its " ; "-joined fields,
    /// trimming each and dropping empties. A "none" response (the model's
    /// "nothing identifiable" / error sentinel) yields no fields.
    public static func parseFields(from response: String?) -> [String] {
        let trimmed = (response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return [] }
        return trimmed.components(separatedBy: " ; ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
