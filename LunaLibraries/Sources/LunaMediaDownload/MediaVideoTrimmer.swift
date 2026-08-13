//
//  MediaVideoTrimmer.swift
//  Luna
//

import LunaModels
import AVFoundation
import Foundation

/// Applies the range carried by YouTube timestamp and clip links after the
/// resumable network transfer is complete. The source is left untouched until
/// export succeeds so the persisted saving stage can retry after termination.
enum MediaVideoTrimmer {
    static func trimIfNeeded(
        fileURL: URL,
        timeRange: MediaTimeRange?
    ) async throws -> URL {
        guard let timeRange, timeRange.isEffective else { return fileURL }

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let start = CMTime(seconds: timeRange.startSeconds, preferredTimescale: 600)
        let requestedEnd = timeRange.endSeconds.map {
            CMTime(seconds: $0, preferredTimescale: 600)
        } ?? duration
        let end = CMTimeMinimum(requestedEnd, duration)
        guard CMTIME_IS_NUMERIC(start), CMTIME_IS_NUMERIC(end),
              CMTimeCompare(start, end) < 0
        else { throw MediaDownloadError.downloadFailed }

        guard let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw MediaDownloadError.downloadFailed }
        let output = MediaDownloadStorage.newFileURL(extension: "mp4")
        try? FileManager.default.removeItem(at: output)
        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = CMTimeRange(start: start, end: end)

        // iOS 18's `export(to:as:)` replaces `exportAsynchronously` plus the
        // `status`/`error` poll it left you to interpret: it throws the failure
        // directly and carries task cancellation itself. The destination moves
        // into the call, so `outputURL`/`outputFileType` are no longer set here
        // (setting them and then calling this is an error).
        try await exporter.export(to: output, as: .mp4)
        return output
    }
}
