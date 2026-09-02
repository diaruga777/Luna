//
//  LiveMediaDownloadManager+PluginReresolve.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import LunaStorage

/// Matches a re-resolved asset back to the leg a job was downloading
/// (`claudedocs/plans/plugin-platform.md` §7.6).
///
/// The pair is `(kind, quality)`: `media_download_jobs` keeps the quality label
/// the resolver gave the leg, so a resumed 1080p transfer comes back as the
/// 1080p leg. A job whose resolver named no quality matches on kind alone and
/// takes the first asset in the plugin's display order, which is the same asset
/// the save chose.
public enum MediaReresolveMatching {
    public static func pick(
        kind: MediaAsset.Kind?, quality: String?, from assets: [MediaAsset]
    ) -> MediaAsset? {
        let sameKind = kind.map { wanted in assets.filter { $0.kind == wanted } } ?? assets
        let candidates = sameKind.isEmpty ? assets : sameKind
        if let quality, let exact = candidates.first(where: { $0.quality == quality }) {
            return exact
        }
        return candidates.first
    }
}

public extension LiveMediaDownloadManager {

    /// The §7.6 re-resolution seam. Stored on `PluginMediaSeams` (LunaModels) so
    /// LunaPluginIngest can install it without importing this module — the
    /// package edge runs the other way and media knows nothing about plugins.
    static var reresolver: (any MediaReresolving)? {
        get { PluginMediaSeams.reresolver }
        set { PluginMediaSeams.reresolver = newValue }
    }

    /// How stale a plugin-owned job may be before a resume re-resolves it
    /// anyway. A CDN URL a plugin returned is short-lived and often IP-bound.
    static var reresolveStaleAge: TimeInterval { 6 * 60 * 60 }

    /// A status a stale CDN URL answers with. Each one is worth one
    /// re-resolution before the job retries or fails.
    static func statusInvitesReresolve(_ status: Int) -> Bool {
        status == 401 || status == 403 || status == 410
    }

    static func headersJSON(_ headers: [String: String]) -> String? {
        guard !headers.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: headers)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func headers(fromJSON json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }

    /// Whether this job's asset URLs must be re-resolved before the transfer is
    /// (re)started: the plugin declared an expiry that has passed, or the job
    /// has been sitting long enough that the URLs are assumed dead.
    static func pluginURLsAreStale(_ job: LiveMediaDownloadJob, now: Date = Date()) -> Bool {
        guard job.pluginID != nil else { return false }
        if let expiresAt = job.expiresAt { return expiresAt <= now }
        guard let touched = lastTouched(job) else { return false }
        return now.timeIntervalSince(touched) >= reresolveStaleAge
    }

    /// The newest write this job made on disk. The schema keeps no creation
    /// time, so the resume blob (or the staged bytes) stands in for one.
    private static func lastTouched(_ job: LiveMediaDownloadJob) -> Date? {
        var candidates: [URL] = []
        if let name = job.resumeDataFileName {
            candidates.append(JobStore.resumeDataURL(fileName: name))
        }
        if let ext = job.fileExtension {
            candidates.append(JobStore.stagingURL(fileName: "\(job.id).source.\(ext)"))
        }
        return candidates.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
        }.max()
    }
}
