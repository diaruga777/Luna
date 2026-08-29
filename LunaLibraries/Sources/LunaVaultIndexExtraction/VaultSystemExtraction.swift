import Foundation
import UniformTypeIdentifiers
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct SystemVaultMediaMetadataProvider: VaultMediaMetadataProviding {
    public init() {}
    public func metadata(for data: Data, contentType: String?, fileName: String) async throws -> VaultExtractedMetadata {
        let route = VaultFileTypeSniffer.route(fileName: fileName, contentType: contentType, data: data)
        #if canImport(ImageIO)
        if route == .image, let dimensions = VaultImageInspector.dimensions(data) {
            return VaultExtractedMetadata(mediaWidth: dimensions.width, mediaHeight: dimensions.height)
        }
        #endif
        return VaultExtractedMetadata(isMetadataOnly: route == .metadataOnly)
    }
}

#if canImport(ImageIO)
private enum VaultImageInspector {
    static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }
}

public struct SystemVaultImagePreparer: VaultImagePreparing {
    public init() {}
    public func prepareForOCR(_ data: Data, policy: VaultExtractionPolicy) async throws -> VaultPreparedImage {
        try Task.checkCancellation()
        guard data.count <= policy.maximumImageInputBytes else { throw VaultExtractionError.unsafeImage("compressed bytes") }
        guard let dimensions = VaultImageInspector.dimensions(data) else { throw VaultExtractionError.malformed("image metadata") }
        guard dimensions.width <= policy.maximumImageDimension, dimensions.height <= policy.maximumImageDimension else { throw VaultExtractionError.unsafeImage("dimension") }
        let (pixels, overflow) = Int64(dimensions.width).multipliedReportingOverflow(by: Int64(dimensions.height))
        guard !overflow, pixels <= policy.maximumImagePixels, pixels <= policy.maximumDecodedImageBytes / 4 else { throw VaultExtractionError.unsafeImage("decoded pixels") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw VaultExtractionError.malformed("image") }
        let target = min(policy.ocrMaximumPixelSize, max(dimensions.width, dimensions.height))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: target]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw VaultExtractionError.malformed("image decode") }
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw VaultExtractionError.malformed("image destination") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VaultExtractionError.malformed("image encode") }
        return VaultPreparedImage(data: output as Data, width: image.width, height: image.height)
    }
}

public struct SystemVaultThumbnailGenerator: VaultThumbnailGenerating {
    public init() {}
    public func thumbnail(for data: Data, contentType: String?, maximumPixelSize: Int) async throws -> Data? {
        let policy = VaultExtractionPolicy(maximumImageInputBytes: min(max(data.count, 1), 64_000_000), ocrMaximumPixelSize: maximumPixelSize)
        return try await SystemVaultImagePreparer().prepareForOCR(data, policy: policy).data
    }
}
#else
public struct SystemVaultImagePreparer: VaultImagePreparing { public init() {}; public func prepareForOCR(_ data: Data, policy: VaultExtractionPolicy) async throws -> VaultPreparedImage { throw VaultExtractionError.unsupported("ImageIO") } }
public struct SystemVaultThumbnailGenerator: VaultThumbnailGenerating { public init() {}; public func thumbnail(for data: Data, contentType: String?, maximumPixelSize: Int) async throws -> Data? { nil } }
#endif

#if canImport(Vision) && canImport(ImageIO)
public struct SystemVaultVisionOCR: VaultVisionOCR {
    public init() {}
    public func recognizeText(from data: Data, contentType: String?) async throws -> [VaultOCRObservation] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw VaultExtractionError.malformed("prepared image") }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                try Task.checkCancellation()
                return (request.results ?? []).compactMap { item in
                    guard let candidate = item.topCandidates(1).first else { return nil }
                    return VaultOCRObservation(text: candidate.string, confidence: Double(candidate.confidence),
                                               boundingBox: VaultNormalizedRect(x: item.boundingBox.origin.x, y: item.boundingBox.origin.y, width: item.boundingBox.width, height: item.boundingBox.height))
                }
            }.value
        }, onCancel: { request.cancel() })
    }
}
#else
public typealias SystemVaultVisionOCR = UnavailableVaultVisionOCR
#endif

#if canImport(Speech)
private final class VaultSpeechRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[VaultSpokenWordSegment], Error>?
    private var task: SFSpeechRecognitionTask?
    private var finished = false

    func install(continuation: CheckedContinuation<[VaultSpokenWordSegment], Error>) {
        lock.withLock { if finished { continuation.resume(throwing: CancellationError()) } else { self.continuation = continuation } }
    }
    func install(task: SFSpeechRecognitionTask) { lock.withLock { if finished { task.cancel() } else { self.task = task } } }
    func finish(_ result: Result<[VaultSpokenWordSegment], Error>) {
        let continuation: CheckedContinuation<[VaultSpokenWordSegment], Error>? = lock.withLock {
            guard !finished else { return nil }; finished = true; task = nil; defer { self.continuation = nil }; return self.continuation
        }
        continuation?.resume(with: result)
    }
    func cancel() {
        let values: (SFSpeechRecognitionTask?, CheckedContinuation<[VaultSpokenWordSegment], Error>?) = lock.withLock {
            guard !finished else { return (nil, nil) }; finished = true; let values = (task, continuation); task = nil; continuation = nil; return values
        }
        values.0?.cancel(); values.1?.resume(throwing: CancellationError())
    }
}

public struct SystemVaultSpeechTranscriber: VaultTranscribing, VaultSpeechSegmentTranscribing {
    public init() {}
    public func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText {
        VaultExtractedText(text: try await transcribeSegments(from: data, contentType: contentType).map(\.text).joined(separator: " "))
    }
    public func transcribeSegments(from data: Data, contentType: String?) async throws -> [VaultSpokenWordSegment] {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw VaultExtractionError.modelUnavailable("on-device Speech") }
        let temporary = try VaultProtectedTemporaryDirectory(prefix: "speech")
        defer { temporary.remove() }
        let audioURL = try temporary.write(data, named: "audio.m4a")
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let state = VaultSpeechRecognitionState()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.install(continuation: continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error { state.finish(.failure(error)); return }
                    guard let result, result.isFinal else { return }
                    state.finish(.success(result.bestTranscription.segments.map {
                        VaultSpokenWordSegment(text: $0.substring, startTime: $0.timestamp, duration: $0.duration)
                    }))
                }
                state.install(task: task)
            }
        }, onCancel: { state.cancel() })
    }
}
#else
public typealias SystemVaultSpeechTranscriber = UnavailableVaultSpeechTranscriber
#endif

#if canImport(AVFoundation)
private final class VaultAudioExportSession: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) { self.value = value }
    func cancel() { value.cancelExport() }
}

public struct SystemVaultAudioPreparer: VaultAudioPreparing {
    public init() {}
    public func prepareAudio(from data: Data, route: VaultFileRoute, contentType: String?, policy: VaultExtractionPolicy) async throws -> VaultPreparedAudio {
        guard Int64(data.count) <= policy.maximumMediaInputBytes else { throw VaultExtractionError.mediaLimit("input bytes") }
        if route == .audio {
            guard Int64(data.count) <= policy.maximumAudioOutputBytes else { throw VaultExtractionError.mediaLimit("audio bytes") }
            return VaultPreparedAudio(data: data)
        }
        guard route == .video else { throw VaultExtractionError.unsupported("audio preparation route") }
        let temporary = try VaultProtectedTemporaryDirectory(prefix: "demux")
        defer { temporary.remove() }
        let inputURL = try temporary.write(data, named: "input.mov")
        let outputURL = temporary.url.appendingPathComponent("audio.m4a")
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0, duration <= policy.maximumMediaDuration else { throw VaultExtractionError.mediaLimit("duration") }
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw VaultExtractionError.noAudioTrack }
        guard let rawExporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw VaultExtractionError.unsupported("audio export") }
        let exporter = VaultAudioExportSession(rawExporter)
        try await withTaskCancellationHandler(operation: {
            try await exporter.value.export(to: outputURL, as: .m4a)
        }, onCancel: { exporter.cancel() })
        try temporary.protect(outputURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount <= policy.maximumAudioOutputBytes else { throw VaultExtractionError.mediaLimit("demux output bytes") }
        return VaultPreparedAudio(data: try Data(contentsOf: outputURL, options: .mappedIfSafe), duration: duration)
    }
}
#else
public struct SystemVaultAudioPreparer: VaultAudioPreparing { public init() {}; public func prepareAudio(from data: Data, route: VaultFileRoute, contentType: String?, policy: VaultExtractionPolicy) async throws -> VaultPreparedAudio { throw VaultExtractionError.unsupported("AVFoundation") } }
#endif

final class VaultProtectedTemporaryDirectory: @unchecked Sendable {
    let url: URL
    init(prefix: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("luna-vault-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        #if os(iOS)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #endif
    }
    func write(_ data: Data, named name: String) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        #if os(iOS)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw VaultExtractionError.malformed("temporary file") }
        #else
        guard FileManager.default.createFile(atPath: fileURL.path, contents: data) else { throw VaultExtractionError.malformed("temporary file") }
        #endif
        return fileURL
    }
    func protect(_ fileURL: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
        #endif
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}
