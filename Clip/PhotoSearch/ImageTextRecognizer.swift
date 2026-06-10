//
//  ImageTextRecognizer.swift
//  clipper
//

import CoreGraphics
import Foundation
import Vision

/// Recognizes literal text in an image (OCR), used to make screenshots,
/// receipts, and signs findable by the words they contain.
protocol ImageTextRecognizer: Sendable {
    /// Returns the recognized text, lowercased and space-joined. Empty if none.
    func recognizeText(in image: CGImage) async -> String
}

/// Apple Vision-backed OCR.
final class VisionImageTextRecognizer: ImageTextRecognizer {

    func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            // `perform` calls the completion handler synchronously and may also
            // throw, so guard against resuming the continuation twice.
            var resumed = false
            func finish(_ text: String) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: text)
            }
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                    .lowercased()
                finish(text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                finish("")
            }
        }
    }
}
