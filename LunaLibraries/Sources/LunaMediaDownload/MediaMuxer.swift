//
//  MediaMuxer.swift
//  Luna
//

import AVFoundation
import Foundation

/// Combines a video-only file and an audio-only file into one playable file.
/// Reddit's DASH pipeline serves video and audio as two separate CDN files —
/// unlike every other supported platform's single-URL asset — so this is the
/// one place that needs a real mux rather than a straight file download.
/// Native AVFoundation composition/export; no third-party (e.g. ffmpeg)
/// dependency.
public enum MediaMuxer {
    public enum MuxError: Error {
        case noVideoTrack
        case exportSessionUnavailable
    }

    public static func mux(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MuxError.noVideoTrack }

        let videoDuration = try await videoAsset.load(.duration)
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: min(videoDuration, audioDuration)),
                of: audioTrack, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
            ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw MuxError.exportSessionUnavailable }

        try? FileManager.default.removeItem(at: outputURL)
        try await export.export(to: outputURL, as: .mp4)
    }
}
