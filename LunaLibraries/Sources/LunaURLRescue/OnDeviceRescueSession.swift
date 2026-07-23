//
//  OnDeviceRescueSession.swift
//  LunaURLRescue
//

// The on-device FoundationModels conformer. Mirrors `FoundationModelsTrimSession`
// in LunaAudioPlayback: the ONLY iOS-26 file here that names a FoundationModels
// type for the text model. iOS 26's `SystemLanguageModel` has a ~4096-token
// context window, so it can never emit a full article — `supportsArticlePayload`
// is always false, and `requestArticlePayload` throws. It CAN do the small plan
// call (reroute / product / webjs / media_url).
//
// Gated by `#if compiler(>=6.4)` NOT because SystemLanguageModel is new (it's
// iOS 26, in the stable SDK), but so this whole seam co-compiles cleanly with
// `PrivateCloudRescueSession` under one toolchain guard; `RescueModelSessionFactory`
// picks the right conformer at runtime.

#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26.0, *)
public final class OnDeviceRescueSession: RescueModelSession {
    private var session: LanguageModelSession?

    public init() {}

    public var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// The 4096-token on-device window can't reproduce a full article.
    public var supportsArticlePayload: Bool { false }

    public func prewarm() {
        currentSession().prewarm()
    }

    public func requestPlan(instructions: String, prompt: String) async throws -> RescuePlanResponse {
        let session = currentSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, generating: RescuePlanDraft.self)
            return response.content.response
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.normalize(error)
        } catch {
            throw RescueModelError.other(error)
        }
    }

    public func requestArticlePayload(instructions: String, prompt: String) async throws -> RescueArticleResponse {
        // The on-device model can't hold a full article — the validator already
        // rejects `kind == "article"` when `!supportsArticlePayload`, so this is
        // belt-and-braces.
        throw RescueModelError.modelUnavailable
    }

    /// One `LanguageModelSession` per rescue attempt, created lazily and reused
    /// (matches `FoundationModelsTrimSession.currentSession`).
    private func currentSession(instructions: String? = nil) -> LanguageModelSession {
        if let session { return session }
        let newSession = instructions.map { LanguageModelSession(instructions: $0) } ?? LanguageModelSession()
        session = newSession
        return newSession
    }

    static func normalize(_ error: LanguageModelSession.GenerationError) -> RescueModelError {
        switch error {
        case .guardrailViolation: return .guardrailViolation
        case .exceededContextWindowSize: return .exceededContextWindowSize
        case .rateLimited: return .rateLimited
        default: return .other(error)
        }
    }
}
#endif
