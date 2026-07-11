//
//  ScreenCaptureModelSession.swift
//  LunaIntents
//

import Foundation

/// The seam every FoundationModels vision type hides behind, so the intent
/// logic that decides WHETHER to run a screenshot extraction (and what to do
/// with the result) is unit-testable with a fake — the real on-device/PCC
/// model is never available in a CI simulator, and the real conformer
/// (`FoundationModelsScreenCaptureSession`) is iOS-27-only and absent from
/// the stable-Xcode SDK entirely (see `ScreenCaptureModelSessionFactory`).
/// Mirrors `AudioTrimModelSession` in `LunaAudioPlayback`.
public protocol ScreenCaptureModelSession: AnyObject {
    /// Mirrors "a vision-capable model — on-device or Private Cloud Compute —
    /// is usable right now."
    var isAvailable: Bool { get }

    /// Runs `prompt` against the screenshot in `imageData`, returning the
    /// model's single raw response string. Throws `ScreenCaptureModelError`
    /// on any failure; callers never see a raw FoundationModels error type.
    func extract(prompt: String, imageData: Data) async throws -> String
}

/// Every screen-capture-model failure this module cares about, normalized so
/// callers never have to name a FoundationModels type directly.
public enum ScreenCaptureModelError: Error {
    /// No vision-capable model is usable — pre-iOS-27 device, Apple
    /// Intelligence off, an Xcode-26.2 archive (the stub build), or the
    /// screenshot data couldn't be decoded into an image.
    case modelUnavailable
    /// The Private Cloud Compute request failed for a network reason.
    case networkFailure
    /// The Private Cloud Compute per-account quota is exhausted.
    case quotaLimitReached
    /// Private Cloud Compute is temporarily unavailable.
    case serviceUnavailable
    /// Any other underlying error, preserved for diagnostics.
    case other(Error)
}

/// Stands in for `FoundationModelsScreenCaptureSession` whenever no
/// vision-capable model can possibly be constructed — a pre-iOS-27 device,
/// or (today) any build compiled with stable Xcode 26.2, whose SDK doesn't
/// have the vision/PCC API surface at all. Always reports unavailable, so
/// callers take exactly the same "no vision model" path they'd take for
/// Apple Intelligence being off.
public final class UnavailableScreenCaptureSession: ScreenCaptureModelSession {
    public init() {}

    public var isAvailable: Bool { false }

    public func extract(prompt: String, imageData: Data) async throws -> String {
        throw ScreenCaptureModelError.modelUnavailable
    }
}
