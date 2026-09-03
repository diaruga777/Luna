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
            instructions: "You continue a piece of writing. Match its voice, tense and Markdown. Add one short paragraph. Answer with the continuation only.")
        let response = try await session.respond(to: context)
        return response.content
    }

    public func rewrite(_ text: String, instruction: String?) async throws -> String {
        let session = LanguageModelSession(
            model: model,
            instructions: "You rewrite a passage. Keep its meaning and its Markdown. Answer with the rewritten passage only.")
        let ask = instruction.map { "\($0)\n\n\(text)" } ?? text
        let response = try await session.respond(to: ask)
        return response.content
    }
}

#endif
