//
//  MLXVLMEngine.swift
//  Clip
//

import CoreGraphics
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// MLX-backed multimodal engine for the applet "contains" check.
///
/// Loads the VLM from its App Group directory **once** and reuses the container for
/// every inference — the model is hundreds of MB and the factory does not cache, so
/// reloading per call would thrash memory.
///
/// The verdict uses **constrained decoding**: rather than generating free text (small
/// VLMs ignore "answer yes/no" and describe the image instead), it runs a single
/// forward pass over the prompt and compares the next-token logits for "yes" vs "no".
/// This is deterministic, can't drift into a description, and is faster (one step, not
/// a token stream).
actor MLXVLMEngine: VLMEngine {

    private let modelDirectory: URL
    private let logger: Logger

    /// The loaded model container, loaded once and reused. Held as a `Task` so that
    /// concurrent first callers await a single load instead of each loading a copy.
    private var containerTask: Task<ModelContainer, Error>?

    /// Token-id candidates whose next-token logit is read for the yes/no decision.
    /// Multiple spellings (and the BPE space-prefixed forms) cover however the model
    /// would start its answer.
    private static let yesSpellings = ["yes", "Yes", "YES", " yes", " Yes"]
    private static let noSpellings = ["no", "No", "NO", " no", " No"]

    init(modelDirectory: URL, logger: Logger) {
        self.modelDirectory = modelDirectory
        self.logger = logger
        // Cap MLX's reusable buffer cache so freed buffers are returned to the OS
        // rather than retained — otherwise peak stays high and backgrounding the app
        // (which has a much lower memory limit) gets the process jetsam-killed.
        MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)
    }

    deinit {
        MLX.GPU.clearCache()
    }

    /// Releases the loaded model and frees GPU memory. Call when a batch of
    /// inferences is done (e.g. after applet backfill) so the ~1GB model isn't held
    /// resident into app backgrounding.
    func unload() {
        containerTask = nil
        MLX.GPU.clearCache()
    }

    private func loadedContainer() async throws -> ModelContainer {
        if let containerTask {
            return try await containerTask.value
        }
        let directory = modelDirectory
        let task = Task {
            try await VLMModelFactory.shared.loadContainer(
                configuration: ModelConfiguration(directory: directory)
            )
        }
        containerTask = task
        do {
            return try await task.value
        } catch {
            containerTask = nil  // Failed load shouldn't be cached; allow a retry.
            throw error
        }
    }

    func contains(image: CGImage, query: String) async throws -> Bool {
        let prompt = "Is there \(query) in this image? Answer yes or no."
        let ciImage = CIImage(cgImage: image)

        do {
            let container = try await loadedContainer()
            let (isYes, yesLogit, noLogit) = try await container.perform {
                (context: ModelContext) async throws -> (Bool, Float, Float) in
                let userInput = UserInput(chat: [.user(prompt, images: [.ciImage(ciImage)])])
                let input = try await context.processor.prepare(input: userInput)

                // A single forward pass over the prompt yields the logits for the next
                // (first answer) token. `prepare` returns those logits for VLMs; fall
                // back to one explicit evaluation otherwise.
                let cache = context.model.newCache(parameters: nil)
                let nextTokenLogits: MLXArray
                switch try context.model.prepare(input, cache: cache, windowSize: nil) {
                case .logits(let output):
                    nextTokenLogits = output.logits[0..., -1, 0...]
                case .tokens(let tokens):
                    nextTokenLogits = context.model(tokens, cache: cache, state: nil).logits[0..., -1, 0...]
                }

                let vocabulary = nextTokenLogits.asType(.float32).asArray(Float.self)

                func bestLogit(for spellings: [String]) -> Float {
                    var ids = Set<Int>()
                    for spelling in spellings {
                        if let first = context.tokenizer.encode(text: spelling, addSpecialTokens: false).first {
                            ids.insert(first)
                        }
                    }
                    return ids.compactMap { $0 < vocabulary.count ? vocabulary[$0] : nil }.max()
                        ?? -Float.greatestFiniteMagnitude
                }

                let yes = bestLogit(for: Self.yesSpellings)
                let no = bestLogit(for: Self.noSpellings)
                return (yes > no, yes, no)
            }
            logger.info("VLM contains \"\(query)\": \(isYes) (yes=\(yesLogit) no=\(noLogit))")
            return isYes
        } catch {
            logger.error("VLM inference failed: \(error)")
            throw VLMEngineError.inferenceFailed(error)
        }
    }
}
