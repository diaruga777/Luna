//
//  MediaUtilCardStorageChoice.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import Photos

/// The media module's answer to the util card's inline "Store downloads …" row
/// (`DownloadStorageChoosing`). Installed by the `KindWiring` of the two apps
/// that download — the other two never link this module, so their card never
/// offers the row.
///
/// The whole point of asking here rather than in Settings is the ORDER: Photos
/// is the shipped default, so an install whose owner never granted Photos access
/// carries a storage setting that quietly does something else (finished
/// downloads fall back to local files). Picking Photos on this row asks the
/// system first and saves the setting only if the answer is yes.
@MainActor
public final class MediaUtilCardStorageChoice: DownloadStorageChoosing {

    private let saver: PhotoLibrarySaving
    /// The current read/write status, injected so a test can pin either answer
    /// without a real photo library behind it.
    private let authorizationStatus: () -> PHAuthorizationStatus

    public init(
        saver: PhotoLibrarySaving = PhotoLibrarySaver(),
        authorizationStatus: @escaping () -> PHAuthorizationStatus = {
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    ) {
        self.saver = saver
        self.authorizationStatus = authorizationStatus
    }

    public static func install() {
        DownloadStorageChoice.installed = MediaUtilCardStorageChoice()
    }

    public var isUnanswered: Bool { !MediaStorageSettings.hasExplicitChoice }

    public var usesPhotos: Bool { MediaStorageSettings.option == .photos }

    /// "In Luna" carries no clock of its own on this row, so it means the
    /// inline age — unless the user already has an age, in which case the row is
    /// only moving them off Photos and must not silently re-time their library.
    public func chooseInLuna() {
        if case .deleteAfter(let existing) = MediaStorageSettings.option {
            MediaStorageSettings.choose(.deleteAfter(existing))
        } else {
            MediaStorageSettings.choose(.deleteAfter(MediaStorageSettings.inlineRetention))
        }
    }

    public func choosePhotos(completion: @escaping (DownloadStoragePhotosOutcome) -> Void) {
        // Already refused: iOS will not show the prompt a second time, so
        // nothing this process does can grant the access — the caller sends the
        // user to Luna's own page in Settings instead.
        switch authorizationStatus() {
        case .denied, .restricted:
            // The setting itself does not move — it is already off Photos —
            // but the row has been answered and does not come back.
            MediaStorageSettings.recordExplicitChoice()
            completion(.refusedBefore)
            return
        default:
            break
        }
        // Read/write rather than add-only: it is the superset both download
        // paths end up needing (`MediaPhotosPreflight`), so one prompt answers
        // every later question.
        Task { @MainActor in
            guard await saver.requestReadAuthorization() else {
                // The setting never moved to Photos, and an install still on the
                // Photos default is left saying something the user just declined.
                chooseInLuna()
                completion(.refused)
                return
            }
            MediaStorageSettings.choose(.photos)
            completion(.granted)
        }
    }
}
