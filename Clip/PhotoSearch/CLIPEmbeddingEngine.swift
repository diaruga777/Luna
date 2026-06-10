//
//  CLIPEmbeddingEngine.swift
//  clipper
//

import CoreGraphics
import CoreML
import Foundation

enum CLIPEmbeddingError: Error {
    case modelLoadFailed(Error)
    case missingImageInput
    case missingTextInput
    case missingOutput
    case imagePreparationFailed(Error)
    case predictionFailed(Error)
}

/// Maps images and text into one shared, L2-normalized embedding space so that a
/// text query and a photo can be compared by cosine similarity (a dot product of
/// normalized vectors).
protocol CLIPEmbeddingEngine: Sendable {
    /// The dimensionality of vectors this engine produces.
    var embeddingDimension: Int { get }

    /// L2-normalized embedding for an image.
    func imageEmbedding(for image: CGImage) async throws -> [Float]

    /// L2-normalized embedding for a text query.
    func textEmbedding(for text: String) async throws -> [Float]
}

/// Core ML-backed engine wrapping a MobileCLIP image encoder and text encoder.
/// Models are loaded lazily on first use. Input/output feature names are
/// discovered from each model's description rather than hard-coded, so the engine
/// tolerates naming differences between exported variants.
actor CoreMLCLIPEmbeddingEngine: CLIPEmbeddingEngine {

    nonisolated let embeddingDimension: Int

    private let model: CLIPModel
    private let imageEncoderURL: URL
    private let textEncoderURL: URL
    private let tokenizer: CLIPTextTokenizer

    private var imageModel: MLModel?
    private var textModel: MLModel?

    /// Small cache of recent query embeddings so re-typing / backspacing a query
    /// is instant and never re-runs the text encoder. Keyed by the exact query.
    private var textCache: [String: [Float]] = [:]
    private var textCacheOrder: [String] = []
    private let textCacheLimit = 128

    init(
        model: CLIPModel,
        imageEncoderURL: URL,
        textEncoderURL: URL,
        tokenizer: CLIPTextTokenizer
    ) {
        self.model = model
        self.embeddingDimension = model.embeddingDimension
        self.imageEncoderURL = imageEncoderURL
        self.textEncoderURL = textEncoderURL
        self.tokenizer = tokenizer
    }

    func imageEmbedding(for image: CGImage) async throws -> [Float] {
        let model = try loadedImageModel()
        guard
            let imageInputName = Self.featureName(in: model.modelDescription.inputDescriptionsByName, ofType: .image),
            let constraint = model.modelDescription.inputDescriptionsByName[imageInputName]?.imageConstraint
        else {
            throw CLIPEmbeddingError.missingImageInput
        }
        // Let Core ML resize and color-convert per the model's image constraint
        // (correct channel order and scaling) instead of hand-building a buffer.
        let featureValue: MLFeatureValue
        do {
            featureValue = try MLFeatureValue(cgImage: image, constraint: constraint, options: nil)
        } catch {
            throw CLIPEmbeddingError.imagePreparationFailed(error)
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [imageInputName: featureValue])
        return try predictEmbedding(model: model, input: input)
    }

    func textEmbedding(for text: String) async throws -> [Float] {
        if let cached = textCache[text] { return cached }

        let model = try loadedTextModel()
        guard let textInputName = Self.featureName(in: model.modelDescription.inputDescriptionsByName, ofType: .multiArray) else {
            throw CLIPEmbeddingError.missingTextInput
        }
        let tokenIDs = tokenizer.encode(text, contextLength: self.model.textContextLength)
        let multiArray = try Self.makeTokenArray(tokenIDs, name: textInputName, model: model)
        let input = try MLDictionaryFeatureProvider(dictionary: [textInputName: MLFeatureValue(multiArray: multiArray)])
        let embedding = try predictEmbedding(model: model, input: input)

        textCache[text] = embedding
        textCacheOrder.append(text)
        if textCacheOrder.count > textCacheLimit {
            let evicted = textCacheOrder.removeFirst()
            textCache[evicted] = nil
        }
        return embedding
    }

    // MARK: - Prediction

    private func predictEmbedding(model: MLModel, input: MLFeatureProvider) throws -> [Float] {
        // Drain Core ML's autoreleased prediction objects (output provider,
        // multi-array) each call so they don't pile up across a long indexing loop.
        try autoreleasepool {
            let output: MLFeatureProvider
            do {
                output = try model.prediction(from: input)
            } catch {
                throw CLIPEmbeddingError.predictionFailed(error)
            }
            guard
                let outputName = Self.featureName(in: model.modelDescription.outputDescriptionsByName, ofType: .multiArray),
                let array = output.featureValue(for: outputName)?.multiArrayValue
            else {
                throw CLIPEmbeddingError.missingOutput
            }
            return Self.l2Normalized(Self.floats(from: array))
        }
    }

    // MARK: - Lazy load

    private func loadedImageModel() throws -> MLModel {
        if let imageModel { return imageModel }
        let model = try load(imageEncoderURL)
        imageModel = model
        return model
    }

    private func loadedTextModel() throws -> MLModel {
        if let textModel { return textModel }
        let model = try load(textEncoderURL)
        textModel = model
        return model
    }

    private func load(_ url: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        // The iOS Simulator's GPU/ANE Core ML path silently produces all-zero
        // outputs for some models (notably weight-quantized ones); CPU is correct
        // there. On device, use every available unit (ANE) for speed.
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        do {
            return try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw CLIPEmbeddingError.modelLoadFailed(error)
        }
    }

    // MARK: - Helpers

    private static func featureName(
        in descriptions: [String: MLFeatureDescription],
        ofType type: MLFeatureType
    ) -> String? {
        descriptions.first { $0.value.type == type }?.key
    }

    private static func makeTokenArray(_ tokenIDs: [Int32], name: String, model: MLModel) throws -> MLMultiArray {
        // Honor the model's declared shape when available (typically [1, 77]);
        // otherwise fall back to a flat sequence.
        let declaredShape = model.modelDescription.inputDescriptionsByName[name]?
            .multiArrayConstraint?.shape.map { $0.intValue }
        let shape = (declaredShape?.isEmpty == false) ? declaredShape! : [1, tokenIDs.count]
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
        // Bind the full element count and zero-fill any slots beyond the token
        // sequence (MLMultiArray storage isn't guaranteed zero-initialized).
        let count = array.count
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: count)
        for index in 0..<count {
            pointer[index] = index < tokenIDs.count ? tokenIDs[index] : 0
        }
        return array
    }

    private static func floats(from array: MLMultiArray) -> [Float] {
        let count = array.count
        var result = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { result[i] = pointer[i] }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count { result[i] = Float(pointer[i]) }
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            for i in 0..<count { result[i] = Float(Float16(bitPattern: pointer[i])) }
        default:
            for i in 0..<count { result[i] = array[i].floatValue }
        }
        return result
    }

    private static func l2Normalized(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for value in vector { sumSquares += value * value }
        let norm = sumSquares.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
