import AVFoundation
import UniformTypeIdentifiers
import LunaVaultSync

/// AVFoundation drives reads and cancellation, including a tail read for MP4
/// metadata. At most two requests run at once, in one-MiB slices; no disk cache.
@MainActor
public final class VaultVideoResourceLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    public let asset: AVURLAsset
    private let source: VaultMediaSource
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    public init(source: VaultMediaSource) {
        self.source = source
        let ext = (source.name as NSString).pathExtension
        asset = AVURLAsset(url: URL(string: "luna-vault-video://stream/\(UUID().uuidString)")!.appendingPathExtension(ext))
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }
    public func cancel() {
        pending.forEach { if !$0.isCancelled { $0.finishLoading(with: CancellationError()) } }; pending.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        asset.cancelLoading()
    }
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = UTType(filenameExtension: (source.name as NSString).pathExtension)?.identifier ?? UTType.movie.identifier
            info.contentLength = source.size; info.isByteRangeAccessSupported = true
        }
        pending.append(request); drain()
        return true
    }
    private func drain() {
        while tasks.count < 2, !pending.isEmpty {
            let request = pending.removeFirst()
            if request.isCancelled { continue }
            let key = ObjectIdentifier(request)
            tasks[key] = Task { [weak self, source] in
                defer { self?.tasks[key] = nil; self?.drain() }
                do {
                    if let dataRequest = request.dataRequest {
                        var offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
                        let (requestedEnd, overflow) = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
                        guard !overflow else { throw CocoaError(.fileReadCorruptFile) }
                        let end = dataRequest.requestsAllDataToEndOfResource ? source.size : min(source.size, requestedEnd)
                        guard offset >= 0, offset <= end else { throw CocoaError(.fileReadCorruptFile) }
                        while offset < end {
                            try Task.checkCancellation()
                            let length = Int(min(1_024 * 1_024, end - offset))
                            let bytes = try await source.read(offset, length)
                            try Task.checkCancellation()
                            guard !request.isCancelled else { return }
                            guard bytes.count == length else { throw CocoaError(.fileReadCorruptFile) }
                            dataRequest.respond(with: bytes); offset += Int64(bytes.count)
                        }
                    }
                    if !request.isCancelled { request.finishLoading() }
                } catch { if !request.isCancelled { request.finishLoading(with: error) } }
            }
        }
    }
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === request }
        // Keep the slot occupied until cancellation has unwound the read.
        tasks[ObjectIdentifier(request)]?.cancel()
    }
}
