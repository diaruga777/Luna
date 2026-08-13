//
//  FoundationModelsScreenCaptureSession.swift
//  LunaIntents
//

// The iOS-27-only FoundationModels vision API (image `Attachment`s,
// `PrivateCloudComputeLanguageModel`, the generic `LanguageModelSession(model:
// some LanguageModel)` init) is completely absent from the iPhoneOS26.2 SDK —
// empirically verified, not inferred. Stable Xcode 26.2 is Swift 6.2.3 and
// takes the `#else` branch below (there is none — the whole file just
// disappears); Xcode 27 beta is Swift 6.4 and takes this path. Since the app
// archives with stable Xcode 26.2 today, any App Store build compiles the
// `UnavailableScreenCaptureSession` stub from `ScreenCaptureModelSession.swift`
// instead of this file — screenshot-based capture only works in builds made
// with Xcode 27 (or later).
#if compiler(>=6.4)
import Foundation
import CoreGraphics
import ImageIO
import FoundationModels

/// The ONLY file in `LunaIntents` (and in the whole vision-capture seam) that
/// imports `FoundationModels` for image/vision use — mirrors
/// `FoundationModelsTrimSession` in `LunaAudioPlayback`. Double-gated: the
/// `#if compiler(>=6.4)` above keeps this file out of an Xcode-26.2 compile
/// entirely, and `@available(iOS 27.0, *)` keeps it from running on an older
/// OS even when compiled by Xcode 27. `ScreenCaptureModelSessionFactory` is
/// the only place that constructs this class.
@available(iOS 27.0, *)
public final class FoundationModelsScreenCaptureSession: ScreenCaptureModelSession {
    public init() {}

    /// True when either the Private Cloud Compute model or a vision-capable
    /// on-device model is usable right now.
    public var isAvailable: Bool {
        if PrivateCloudComputeLanguageModel().availability == .available {
            return true
        }
        let onDevice = SystemLanguageModel.default
        return onDevice.isAvailable && onDevice.capabilities.contains(.vision)
    }

    /// Decodes `imageData` into a `CGImage`, picks the Private Cloud Compute
    /// model when it's available (no on-device vision requirement), else
    /// falls back to the on-device model when it's both available AND
    /// vision-capable, then runs `prompt` + the image through it. Throws
    /// `.modelUnavailable` when the image can't be decoded or neither model
    /// applies.
    public func extract(prompt: String, imageData: Data) async throws -> String {
        guard let cgImage = Self.makeCGImage(from: imageData) else {
            throw ScreenCaptureModelError.modelUnavailable
        }

        let pccModel = PrivateCloudComputeLanguageModel()
        if pccModel.availability == .available {
            let session = LanguageModelSession(model: pccModel)
            return try await Self.respond(session: session, prompt: prompt, cgImage: cgImage)
        }

        let onDevice = SystemLanguageModel.default
        guard onDevice.isAvailable, onDevice.capabilities.contains(.vision) else {
            throw ScreenCaptureModelError.modelUnavailable
        }
        let session = LanguageModelSession(model: onDevice)
        return try await Self.respond(session: session, prompt: prompt, cgImage: cgImage)
    }

    /// Shared by both model branches — `LanguageModelSession` itself isn't
    /// generic (the `model:` initializer is a generic convenience init that
    /// still produces a plain `LanguageModelSession`), so there's no opaque-
    /// or existential-type friction in sharing this helper across the PCC and
    /// on-device paths.
    private static func respond(session: LanguageModelSession, prompt: String, cgImage: CGImage) async throws -> String {
        do {
            let response = try await session.respond(to: Prompt {
                prompt
                Attachment(cgImage)
            })
            return response.content
        } catch let pccError as PrivateCloudComputeLanguageModel.Error {
            throw normalize(pccError)
        } catch {
            throw ScreenCaptureModelError.other(error)
        }
    }

    private static func normalize(_ error: PrivateCloudComputeLanguageModel.Error) -> ScreenCaptureModelError {
        switch error {
        case .networkFailure: return .networkFailure
        case .quotaLimitReached: return .quotaLimitReached
        case .serviceUnavailable: return .serviceUnavailable
        // Non-frozen: a case added by a later SDK keeps its underlying error
        // for diagnostics rather than being silently mapped onto a sibling.
        @unknown default: return .other(error)
        }
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
#endif
