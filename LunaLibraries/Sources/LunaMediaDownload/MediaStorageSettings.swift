//
//  MediaStorageSettings.swift
//  LunaMediaDownload
//

import Foundation

/// The single "Storage" choice Downloader Settings shows: finished downloads
/// either go to the photo library and stay there, or stay in Luna and are
/// deleted automatically after a chosen age. The two are mutually exclusive —
/// that exclusivity is the whole point of collapsing the old independent
/// "Auto-Save to Photos" toggle and "Delete After" picker into one row.
public enum MediaStorageOption: Equatable, Sendable {
    /// Save completed downloads into Photos; Luna applies no deletion clock.
    case photos
    /// Keep completed downloads in Luna, deleting them once they reach this age.
    case deleteAfter(MediaRetentionOption)

    /// Photos first, then the deletion ages in ascending order.
    public static var allCases: [MediaStorageOption] {
        [.photos] + MediaRetentionOption.deletionOptions.map(Self.deleteAfter)
    }

    public var displayName: String {
        switch self {
        case .photos: return "Save to Photos"
        case .deleteAfter(let retention): return "Delete after \(retention.displayName)"
        }
    }
}

public enum MediaStorageSettings {
    /// The default deletion age for an installation that has Photos off but no
    /// retention choice recorded (the old settings allowed that combination; the
    /// new one doesn't).
    public static let defaultRetention: MediaRetentionOption = .oneMonth

    /// Reads and writes the two underlying prefs
    /// (`AutoDownloadSettings.autoSaveDownloadsToPhotos` and
    /// `MediaRetentionSettings.option`) as one exclusive choice, so every
    /// existing consumer of those prefs keeps working unchanged.
    public static var option: MediaStorageOption {
        get {
            guard !AutoDownloadSettings.autoSaveDownloadsToPhotos else { return .photos }
            let retention = MediaRetentionSettings.option
            return .deleteAfter(retention == .never ? defaultRetention : retention)
        }
        set {
            switch newValue {
            case .photos:
                AutoDownloadSettings.autoSaveDownloadsToPhotos = true
                MediaRetentionSettings.option = .never
            case .deleteAfter(let retention):
                AutoDownloadSettings.autoSaveDownloadsToPhotos = false
                MediaRetentionSettings.option =
                    retention == .never ? defaultRetention : retention
            }
        }
    }
}
