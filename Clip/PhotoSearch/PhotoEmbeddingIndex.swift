//
//  PhotoEmbeddingIndex.swift
//  clipper
//

import Foundation

/// One indexed photo: its embedding in the shared CLIP space plus the lowercased
/// text recognized in it (OCR) for literal-text matching.
struct PhotoIndexEntry: Codable, Sendable, Equatable {
    let localIdentifier: String
    let embedding: [Float]
    let ocrText: String
    let creationDate: Date
}

/// The persisted on-device search index. Vectors are only comparable within a
/// single `modelIdentifier`; switching models invalidates the index.
struct PhotoEmbeddingIndex: Codable, Sendable, Equatable {
    let modelIdentifier: String
    let embeddingDimension: Int
    var entries: [PhotoIndexEntry]

    init(modelIdentifier: String, embeddingDimension: Int, entries: [PhotoIndexEntry] = []) {
        self.modelIdentifier = modelIdentifier
        self.embeddingDimension = embeddingDimension
        self.entries = entries
    }
}
