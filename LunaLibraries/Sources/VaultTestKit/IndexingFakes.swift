import Foundation
import LunaVaultEmbeddings
import LunaVaultIndexExtraction

public enum VaultFakeControl<Value: Sendable>: Sendable {
    case success(Value)
    case failure(VaultFakeInjectedError)
    case cancellation
}

public struct VaultFakeInjectedError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public struct VaultExtractionCall: Equatable, Sendable {
    public let data: Data
    public let contentType: String?

    public init(data: Data, contentType: String?) {
        self.data = data
        self.contentType = contentType
    }
}

public struct VaultEmbeddingCall: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public final class VaultFakeTextExtractor: VaultTextExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private let control: VaultFakeControl<VaultExtractedText>
    private var storedCalls: [VaultExtractionCall] = []

    public init(text: String) {
        control = .success(VaultExtractedText(text: text))
    }

    public init(control: VaultFakeControl<VaultExtractedText>) {
        self.control = control
    }

    public func extractText(from data: Data, contentType: String?) async throws -> VaultExtractedText {
        lock.withLock { storedCalls.append(VaultExtractionCall(data: data, contentType: contentType)) }
        switch control {
        case let .success(value): return value
        case let .failure(error): throw error
        case .cancellation: throw CancellationError()
        }
    }

    public var calls: [VaultExtractionCall] { lock.withLock { storedCalls } }
}

public final class VaultFakeTranscriber: VaultTranscribing, VaultSpeechSegmentTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private let control: VaultFakeControl<VaultExtractedText>
    private var storedCalls: [VaultExtractionCall] = []

    public init(transcript: String) {
        control = .success(VaultExtractedText(text: transcript))
    }

    public init(control: VaultFakeControl<VaultExtractedText>) {
        self.control = control
    }

    public func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText {
        lock.withLock { storedCalls.append(VaultExtractionCall(data: data, contentType: contentType)) }
        switch control {
        case let .success(value): return value
        case let .failure(error): throw error
        case .cancellation: throw CancellationError()
        }
    }

    public func transcribeSegments(from data: Data, contentType: String?) async throws -> [VaultSpokenWordSegment] {
        let text = try await transcribeSpokenWords(from: data, contentType: contentType).text
        return [VaultSpokenWordSegment(text: text, startTime: 0, duration: 0)]
    }

    public var calls: [VaultExtractionCall] { lock.withLock { storedCalls } }
}

public final class VaultFakeEmbedder: VaultEmbeddingGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private let control: VaultFakeControl<VaultEmbedding>
    private var storedCalls: [VaultEmbeddingCall] = []

    public init(values: [Float], modelVersion: String = "vault-test-model-v1") {
        control = .success(VaultEmbedding(values: values, modelVersion: modelVersion))
    }

    public init(control: VaultFakeControl<VaultEmbedding>) {
        self.control = control
    }

    public func embedding(for text: String) async throws -> VaultEmbedding {
        lock.withLock { storedCalls.append(VaultEmbeddingCall(text: text)) }
        switch control {
        case let .success(value): return value
        case let .failure(error): throw error
        case .cancellation: throw CancellationError()
        }
    }

    public var calls: [VaultEmbeddingCall] { lock.withLock { storedCalls } }
}
