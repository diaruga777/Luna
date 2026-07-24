//
//  MediaDownloadPreflight.swift
//  Luna
//

import LunaModels
import Foundation
import LunaURLClassification

public struct MediaDownloadInspection: Equatable {
    public let asset: MediaAsset
    public let expectedByteCount: Int64?

    public init(asset: MediaAsset, expectedByteCount: Int64?) {
        self.asset = asset
        self.expectedByteCount = expectedByteCount
    }
}

/// Central policy for downloads that may be much larger than a social clip.
public enum MediaStoragePolicy {
    /// Leave room for system operation, URLSession's partial file, thumbnails,
    /// and a short-lived export/move during finalization.
    public static let reserveByteCount: Int64 = 256 * 1_024 * 1_024

    public static func requiredByteCount(
        expectedByteCount: Int64?, requiresProcessingCopy: Bool = false
    ) -> Int64 {
        guard let expectedByteCount, expectedByteCount > 0 else {
            return reserveByteCount
        }
        let overhead = max(Int64(32 * 1_024 * 1_024), expectedByteCount / 10)
        let processingCopy = requiresProcessingCopy ? expectedByteCount : 0
        return expectedByteCount + processingCopy + reserveByteCount + overhead
    }

    public static func hasCapacity(
        expectedByteCount: Int64?, availableByteCount: Int64?,
        requiresProcessingCopy: Bool = false
    ) -> Bool {
        guard let availableByteCount else { return true }
        return availableByteCount >= requiredByteCount(
            expectedByteCount: expectedByteCount,
            requiresProcessingCopy: requiresProcessingCopy)
    }
}

/// App Intents should not hold the Shortcuts process open for large or
/// indeterminate downloads. Existing durable files bypass this policy because no
/// network download is performed.
public enum IntentMediaDownloadPolicy {
    public static let inlineByteLimit: Int64 = 100 * 1_024 * 1_024

    public static func shouldAwait(expectedByteCount: Int64?) -> Bool {
        guard let expectedByteCount, expectedByteCount >= 0 else { return false }
        return expectedByteCount <= inlineByteLimit
    }
}

public enum MediaDownloadPreflight {
    public static func inspect(
        sourceURL: URL,
        resolver: SocialMediaResolving = SocialMediaResolver()
    ) async -> MediaDownloadInspection? {
        guard let asset = await resolver.resolveAssets(for: sourceURL).first else {
            return nil
        }
        let expected = await expectedByteCount(for: asset, sourceURL: sourceURL)
        return MediaDownloadInspection(asset: asset, expectedByteCount: expected)
    }

    public static func expectedByteCount(
        for asset: MediaAsset,
        sourceURL: URL,
        session: URLSession = .shared
    ) async -> Int64? {
        if let advertised = asset.estimatedByteCount, advertised > 0 {
            return advertised
        }
        var request = URLRequest(url: asset.url, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let host = sourceURL.host?.lowercased() ?? ""
        if HostMatching.hostSuffixMatches(host, "tiktok.com") {
            request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        } else if HostMatching.hostSuffixMatches(host, anyOf: ["reddit.com", "redd.it"]) {
            request.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
        } else if PlatformRecognizer.recognize(sourceURL.absoluteString)?.platform == .youtube {
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode),
              response.expectedContentLength > 0
        else { return nil }
        return response.expectedContentLength
    }

    public static func availableByteCount(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static func storageError(
        expectedByteCount: Int64?,
        directory: URL = MediaDownloadStorage.directory,
        requiresProcessingCopy: Bool = false
    ) -> MediaDownloadError? {
        let available = availableByteCount(at: directory)
        guard !MediaStoragePolicy.hasCapacity(
            expectedByteCount: expectedByteCount,
            availableByteCount: available,
            requiresProcessingCopy: requiresProcessingCopy)
        else { return nil }
        return .insufficientStorage(
            requiredBytes: MediaStoragePolicy.requiredByteCount(
                expectedByteCount: expectedByteCount,
                requiresProcessingCopy: requiresProcessingCopy),
            availableBytes: available)
    }

    public static func storageError(
        for inspection: MediaDownloadInspection,
        directory: URL = MediaDownloadStorage.directory
    ) -> MediaDownloadError? {
        storageError(
            expectedByteCount: inspection.expectedByteCount,
            directory: directory,
            requiresProcessingCopy: inspection.asset.timeRange?.isEffective == true)
    }
}
