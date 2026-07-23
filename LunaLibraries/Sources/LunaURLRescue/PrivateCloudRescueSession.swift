//
//  PrivateCloudRescueSession.swift
//  LunaURLRescue
//

// The Private-Cloud-Compute-preferring conformer. Mirrors
// `FoundationModelsScreenCaptureSession` in LunaIntents VERBATIM: the iOS-27-only
// `PrivateCloudComputeLanguageModel` (and the generic `LanguageModelSession(model:)`
// init) are ABSENT from the stable iPhoneOS 26.2 SDK, so this whole file is gated
// behind `#if compiler(>=6.4)` (Xcode 27 beta / Swift 6.4) AND `@available(iOS 27.0, *)`.
// Any App Store build made with stable Xcode 26.2 compiles the on-device
// conformer / the unavailable stub instead — full-article rescue only works in
// Xcode-27 builds. PCC's ~32k-token window is what makes `supportsArticlePayload`
// viable.

#if compiler(>=6.4)
import Foundation
import FoundationModels

@available(iOS 27.0, *)
public final class PrivateCloudRescueSession: RescueModelSession {
    /// One session per rescue attempt, reused across the plan + payload calls.
    private var session: LanguageModelSession?
    /// Whether the session we created is the PCC-backed one (drives
    /// `supportsArticlePayload`). Resolved on first use.
    private var usingPrivateCloud = false

    public init() {}

    public var isAvailable: Bool {
        if PrivateCloudComputeLanguageModel().availability == .available { return true }
        return SystemLanguageModel.default.availability == .available
    }

    /// Only the PCC model's large window can reproduce a full article.
    public var supportsArticlePayload: Bool {
        PrivateCloudComputeLanguageModel().availability == .available
    }

    public func prewarm() {
        currentSession().prewarm()
    }

    public func requestPlan(instructions: String, prompt: String) async throws -> RescuePlanResponse {
        let session = currentSession(instructions: instructions)
        return try await respondPlan(session: session, prompt: prompt)
    }

    public func requestArticlePayload(instructions: String, prompt: String) async throws -> RescueArticleResponse {
        // Reuse the same session (so the model retains the plan-call context), but
        // the article call only makes sense on the PCC model.
        guard usingPrivateCloud else { throw RescueModelError.modelUnavailable }
        let session = currentSession(instructions: instructions)
        return try await respondArticle(session: session, prompt: prompt)
    }

    private func respondPlan(session: LanguageModelSession, prompt: String) async throws -> RescuePlanResponse {
        do {
            let response = try await session.respond(to: prompt, generating: RescuePlanDraft.self)
            return response.content.response
        } catch let pccError as PrivateCloudComputeLanguageModel.Error {
            throw Self.normalize(pccError)
        } catch let error as LanguageModelSession.GenerationError {
            throw OnDeviceRescueSession.normalize(error)
        } catch {
            throw RescueModelError.other(error)
        }
    }

    private func respondArticle(session: LanguageModelSession, prompt: String) async throws -> RescueArticleResponse {
        do {
            let response = try await session.respond(to: prompt, generating: RescueArticleDraft.self)
            return response.content.response
        } catch let pccError as PrivateCloudComputeLanguageModel.Error {
            throw Self.normalize(pccError)
        } catch let error as LanguageModelSession.GenerationError {
            throw OnDeviceRescueSession.normalize(error)
        } catch {
            throw RescueModelError.other(error)
        }
    }

    /// Prefer PCC (large window, article payloads); fall back to the on-device
    /// model when PCC isn't available right now — one session per attempt.
    private func currentSession(instructions: String? = nil) -> LanguageModelSession {
        if let session { return session }
        let pccModel = PrivateCloudComputeLanguageModel()
        let newSession: LanguageModelSession
        if pccModel.availability == .available {
            usingPrivateCloud = true
            newSession = instructions.map { LanguageModelSession(model: pccModel, instructions: $0) }
                ?? LanguageModelSession(model: pccModel)
        } else {
            usingPrivateCloud = false
            newSession = instructions.map { LanguageModelSession(instructions: $0) }
                ?? LanguageModelSession()
        }
        session = newSession
        return newSession
    }

    static func normalize(_ error: PrivateCloudComputeLanguageModel.Error) -> RescueModelError {
        switch error {
        case .networkFailure: return .networkFailure
        case .quotaLimitReached: return .quotaLimitReached
        case .serviceUnavailable: return .serviceUnavailable
        }
    }
}
#endif
