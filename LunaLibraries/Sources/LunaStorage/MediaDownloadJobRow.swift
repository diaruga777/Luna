//
//  MediaDownloadJobRow.swift
//  LunaStorage
//

import Foundation
import LunaModels

/// The `media_download_jobs` row for one in-flight download, and the mapping to
/// and from `LiveMediaDownloadJob`.
///
/// Every enum is stored as its raw string and mapped back through
/// `init(rawValue:)`, so a value a newer sibling app wrote reads as nil rather
/// than failing the row — the same rule every other enum column here follows. The
/// one exception is `phase`, which has no safe default: a job whose phase this
/// binary cannot name is one it must not act on, so such a row is skipped
/// entirely rather than guessed at.
enum MediaDownloadJobRow {

    static let selectSQL = """
        SELECT id, source_url_string, asset_url_string, audio_url_string,
               dash_manifest_url_string, media_kind, title, resolve_kind, phase,
               progress, thumbnail_file_name, file_extension, expected_byte_count,
               received_byte_count, resume_data_file_name, time_range_start,
               time_range_end, resolved_video_id, youtube_visitor_data,
               error_message, error_kind, resolve_attempts, media_attempts,
               suspend_deadline, ownership, background_session_identifier,
               plugin_id, request_headers_json, expires_at, quality
        FROM media_download_jobs
        """

    static let upsertSQL = """
        INSERT INTO media_download_jobs (
            id, source_url_string, asset_url_string, audio_url_string,
            dash_manifest_url_string, media_kind, title, resolve_kind, phase,
            progress, thumbnail_file_name, file_extension, expected_byte_count,
            received_byte_count, resume_data_file_name, time_range_start,
            time_range_end, resolved_video_id, youtube_visitor_data,
            error_message, error_kind, resolve_attempts, media_attempts,
            suspend_deadline, ownership, background_session_identifier,
            plugin_id, request_headers_json, expires_at, quality)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
            source_url_string = excluded.source_url_string,
            asset_url_string = excluded.asset_url_string,
            audio_url_string = excluded.audio_url_string,
            dash_manifest_url_string = excluded.dash_manifest_url_string,
            media_kind = excluded.media_kind,
            title = excluded.title,
            resolve_kind = excluded.resolve_kind,
            phase = excluded.phase,
            progress = excluded.progress,
            thumbnail_file_name = excluded.thumbnail_file_name,
            file_extension = excluded.file_extension,
            expected_byte_count = excluded.expected_byte_count,
            received_byte_count = excluded.received_byte_count,
            resume_data_file_name = excluded.resume_data_file_name,
            time_range_start = excluded.time_range_start,
            time_range_end = excluded.time_range_end,
            resolved_video_id = excluded.resolved_video_id,
            youtube_visitor_data = excluded.youtube_visitor_data,
            error_message = excluded.error_message,
            error_kind = excluded.error_kind,
            resolve_attempts = excluded.resolve_attempts,
            media_attempts = excluded.media_attempts,
            suspend_deadline = excluded.suspend_deadline,
            ownership = excluded.ownership,
            background_session_identifier = excluded.background_session_identifier,
            plugin_id = excluded.plugin_id,
            request_headers_json = excluded.request_headers_json,
            expires_at = excluded.expires_at,
            quality = excluded.quality
        """

    static func bindUpsert(_ job: LiveMediaDownloadJob, to s: SavesStatement) throws {
        try s.bind(1, job.id)
        try s.bind(2, job.sourceURLString)
        try s.bind(3, job.assetURLString)
        try s.bind(4, job.audioURLString)
        try s.bind(5, job.dashManifestURLString)
        try s.bind(6, job.mediaKind?.rawValue)
        try s.bind(7, job.title)
        try s.bind(8, job.resolveKind?.rawValue)
        try s.bind(9, job.phase.rawValue)
        try s.bind(10, job.progress)
        try s.bind(11, job.thumbnailFileName)
        try s.bind(12, job.fileExtension)
        try s.bind(13, int64: job.expectedByteCount)
        try s.bind(14, int64: job.receivedByteCount)
        try s.bind(15, job.resumeDataFileName)
        try s.bind(16, job.timeRange?.startSeconds)
        try s.bind(17, job.timeRange?.endSeconds)
        try s.bind(18, job.resolvedVideoID)
        try s.bind(19, job.youtubeVisitorData)
        try s.bind(20, job.errorMessage)
        try s.bind(21, job.errorKind?.rawValue)
        try s.bind(22, job.resolveAttempts)
        try s.bind(23, job.mediaAttempts)
        try s.bind(24, date: job.suspendDeadline)
        try s.bind(25, job.ownership?.rawValue)
        try s.bind(26, job.backgroundSessionIdentifier)
        try s.bind(27, job.pluginID)
        try s.bind(28, job.requestHeadersJSON)
        try s.bind(29, date: job.expiresAt)
        try s.bind(30, job.quality)
    }

    static func job(from row: SavesStatement) -> LiveMediaDownloadJob? {
        guard let id = row.string(0),
              let sourceURLString = row.string(1),
              let title = row.string(6),
              let phase = row.string(8).flatMap(LiveMediaDownloadJob.Phase.init(rawValue:))
        else { return nil }
        return LiveMediaDownloadJob(
            id: id,
            sourceURLString: sourceURLString,
            assetURLString: row.string(2),
            mediaKind: row.string(5).flatMap(MediaAsset.Kind.init(rawValue:)),
            title: title,
            resolveKind: row.string(7).flatMap(LiveMediaDownloadJob.ResolveKind.init(rawValue:)),
            phase: phase,
            progress: row.double(9) ?? 0,
            thumbnailFileName: row.string(10),
            fileExtension: row.string(11),
            expectedByteCount: row.int64OrNil(12),
            receivedByteCount: row.int64OrNil(13),
            resumeDataFileName: row.string(14),
            timeRange: row.double(15).map {
                MediaTimeRange(startSeconds: $0, endSeconds: row.double(16))
            },
            resolvedVideoID: row.string(17),
            youtubeVisitorData: row.string(18),
            errorMessage: row.string(19),
            errorKind: row.string(20).flatMap(LiveMediaDownloadJob.ErrorKind.init(rawValue:)),
            resolveAttempts: row.int(21) ?? 0,
            mediaAttempts: row.int(22) ?? 0,
            suspendDeadline: row.date(23),
            ownership: row.string(24).flatMap(LiveMediaDownloadOwnership.init(rawValue:)),
            backgroundSessionIdentifier: row.string(25),
            audioURLString: row.string(3),
            dashManifestURLString: row.string(4),
            pluginID: row.string(26),
            requestHeadersJSON: row.string(27),
            expiresAt: row.date(28),
            quality: row.string(29))
    }
}
