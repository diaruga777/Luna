//
//  MediaStorageSettings.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels

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
        case .photos: return L10n.string("Settings_autoDownload_storageOption_photosTitle")
        case .deleteAfter(let retention):
            return L10n.string(
                "Settings_autoDownload_storageOption_deleteAfterTitle", retention.displayName)
        }
    }
}

public enum MediaStorageSettings {
    /// The default deletion age for an installation that has Photos off but no
    /// retention choice recorded (the old settings allowed that combination; the
    /// new one doesn't).
    public static let defaultRetention: MediaRetentionOption = .oneMonth

    /// The age "in Luna" means when it is picked from the util card's inline
    /// row, which offers Luna-or-Photos and no clock. Deliberately shorter than
    /// `defaultRetention`: the card's choice is made before the user has any
    /// downloads to judge by, and a month of video is a lot to opt into blind.
    public static let inlineRetention: MediaRetentionOption = .twoWeeks

    private static let explicitChoiceKey = "mediaStorage.userChose.v1"

    /// Whether the user has ever answered the Storage question themselves.
    /// False on a fresh install — where `option` is the shipped default rather
    /// than anything anyone said — which is what the util card's inline row
    /// waits on.
    public static var hasExplicitChoice: Bool {
        AutoDownloadSettings.defaults.bool(forKey: explicitChoiceKey)
    }

    /// Records that the answer standing in `option` is the user's own, without
    /// changing it. The one caller is a Photos refusal: the user answered the
    /// row, the setting simply could not follow them there.
    public static func recordExplicitChoice() {
        AutoDownloadSettings.defaults.set(true, forKey: explicitChoiceKey)
    }

    /// `option`, set by the user rather than by Luna. Every user-facing control
    /// writes through here so the util card's inline row retires once the
    /// question has been answered ANYWHERE — the card or Settings → Downloads.
    public static func choose(_ newValue: MediaStorageOption) {
        option = newValue
        recordExplicitChoice()
    }

    /// Reads and writes the two underlying prefs
    /// (`AutoDownloadSettings.autoSaveDownloadsToPhotos` and
    /// `MediaRetentionSettings.option`) as one exclusive choice, so every
    /// existing consumer of those prefs keeps working unchanged. `set` always
    /// writes both prefs together, so retention can never go stale at `.never`
    /// while Photos is off. `autoSaveDownloadsToPhotos`'s own setter is
    /// module-internal, making this (alongside `AutoDownloadSettings.policy`
    /// for its own pair) the only way to change either pref from outside the
    /// module.
    public static var option: MediaStorageOption {
        get {
            guard !AutoDownloadSettings.autoSaveDownloadsToPhotos else { return .photos }
            return .deleteAfter(MediaRetentionSettings.option)
        }
        set {
            switch newValue {
            case .photos:
                AutoDownloadSettings.autoSaveDownloadsToPhotos = true
                MediaRetentionSettings.option = .never
            case .deleteAfter(let retention):
                AutoDownloadSettings.autoSaveDownloadsToPhotos = false
                MediaRetentionSettings.option = retention
            }
        }
    }
}
