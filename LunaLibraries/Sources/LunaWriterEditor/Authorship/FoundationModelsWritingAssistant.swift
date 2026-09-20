//
//  FoundationModelsWritingAssistant.swift
//  LunaWriterEditor
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)

/// The on-device system model, asked for the two edits the plan names.
///
/// A device with no model answers `isAvailable == false` and the editor
/// offers neither command, so nothing here ever fails in front of a writer.
@available(iOS 26, *)
public final class FoundationModelsWritingAssistant: AIWritingAssisting {

    public let modelIdentifier: String
    private let model: SystemLanguageModel

    public init(modelIdentifier: String = "apple-on-device") {
        self.modelIdentifier = modelIdentifier
        model = SystemLanguageModel.default
    }

    public var isAvailable: Bool { model.isAvailable }

    public func continueWriting(context: String) async throws -> String {
        let session = LanguageModelSession(
            model: model,
            instructions: "You continue a piece of writing where it stops. Write one short paragraph that follows naturally, in the same voice, tense, person and Markdown style, without repeating or summarizing what is already written. Answer with the new paragraph only: no preamble, no quotes, no closing remark.")
        let response = try await session.respond(to: context)
        return response.content
    }

    public func rewrite(_ text: String, instruction: String?) async throws -> String {
        let session = LanguageModelSession(
            model: model,
            instructions: "You rewrite a passage. Keep its meaning, its facts, its length and its Markdown. Follow the instruction that precedes the passage when there is one; otherwise make it clearer and tighter in the same voice. Answer with the rewritten passage only: no preamble, no quotes, no explanation.")
        let ask = instruction.map { "\($0)\n\n\(text)" } ?? text
        let response = try await session.respond(to: ask)
        return response.content
    }
}

#endif
