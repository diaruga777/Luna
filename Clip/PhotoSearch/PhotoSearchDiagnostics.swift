//
//  PhotoSearchDiagnostics.swift
//  clipper
//

import CoreGraphics
import Foundation

/// On-device self-test for the CLIP engines, run only when the app is launched
/// with `-photoSearchSelfTest YES`. Embeds two solid-color images and matching
/// text queries and logs the cosine similarities, so engine failures or
/// degenerate output can be diagnosed on the actual (simulator/device) Core ML
/// runtime without driving the UI.
enum PhotoSearchDiagnostics {

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "photoSearchSelfTest")
    }

    static func run(engineProvider: CLIPEngineProvider, modelManager: CLIPModelManager, logger: Logger) {
        Task {
            let red = solidImage(red: 0.85, green: 0.05, blue: 0.05)
            let blue = solidImage(red: 0.05, green: 0.10, blue: 0.85)

            for model in CLIPModel.allCases {
                // The Vision baseline has no embedding engine; it's exercised via
                // the indexing/label path, not this CLIP cosine probe.
                if case .system = model.source { continue }
                guard modelManager.isDownloaded(model) else {
                    logger.info("[selftest] \(model.rawValue): not downloaded, skipping")
                    continue
                }
                guard let engine = engineProvider.makeEngine(for: model) else {
                    logger.error("[selftest] \(model.rawValue): makeEngine returned nil")
                    continue
                }
                do {
                    let redEmb = try await engine.imageEmbedding(for: red)
                    let blueEmb = try await engine.imageEmbedding(for: blue)
                    let redTxt = try await engine.textEmbedding(for: "a red square")
                    let blueTxt = try await engine.textEmbedding(for: "a blue square")
                    func cos(_ a: [Float], _ b: [Float]) -> Float {
                        var s: Float = 0
                        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
                        return s
                    }
                    logger.info("""
                    [selftest] \(model.rawValue) dims img=\(redEmb.count) txt=\(redTxt.count) | \
                    red·red=\(cos(redEmb, redTxt)) red·blue=\(cos(redEmb, blueTxt)) | \
                    blue·blue=\(cos(blueEmb, blueTxt)) blue·red=\(cos(blueEmb, redTxt))
                    """)
                } catch {
                    logger.error("[selftest] \(model.rawValue) FAILED: \(error)")
                }
            }
            // Exercise the Apple Vision analyzer on the real runtime to confirm
            // VNClassifyImageRequest/OCR don't crash and produce searchable text.
            let vision = VisionFrameAnalyzer(textRecognizer: VisionImageTextRecognizer())
            if let redAnalysis = await vision.analyze(image: red),
               let blueAnalysis = await vision.analyze(image: blue) {
                logger.info("[selftest] appleVision red labels=\"\(redAnalysis.searchableText)\" blue labels=\"\(blueAnalysis.searchableText)\"")
            } else {
                logger.error("[selftest] appleVision analyze returned nil")
            }

            logger.info("[selftest] done")
        }
    }

    private static func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        return context.makeImage()!
    }
}
