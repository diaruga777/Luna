//
//  MediaUtilCardStorageChoice.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import Photos

/// Where the current photo-library read/write status comes from, so a test can
/// pin either answer without a real photo library behind it.
public protocol PhotoLibraryAuthorizationProbing {
    var readWriteStatus: PHAuthorizationStatus { get }
}

/// The production probe: the real library's status.
public struct PhotoLibraryAuthorizationProbe: PhotoLibraryAuthorizationProbing {
    public init() {}

    public var readWriteStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
}

/// The media module's answer to the util card's inline "Store downloads …" row
/// (`DownloadStorageChoosing`). Installed by the `KindWiring` of the two apps
/// that download — the other two never link this module, so their card never
/// offers the row.
///
/// The whole point of asking here rather than in Settings is the ORDER: Luna is
/// the shipped default, so a fresh install never needs Photos access before it
/// has asked for it. Picking Photos on this row asks the
/// system first and saves the setting only if the answer is yes.
@MainActor
public final class MediaUtilCardStorageChoice: DownloadStorageChoosing {

    private let saver: PhotoLibrarySaving
    private let authorization: PhotoLibraryAuthorizationProbing

    public init(
        saver: PhotoLibrarySaving = PhotoLibrarySaver(),
        authorization: PhotoLibraryAuthorizationProbing = PhotoLibraryAuthorizationProbe()
    ) {
        self.saver = saver
        self.authorization = authorization
    }

    public static func install() {
        DownloadStorageChoice.installed = MediaUtilCardStorageChoice()
    }

    public var isUnanswered: Bool { !MediaStorageSettings.hasExplicitChoice }

    public var usesPhotos: Bool { MediaStorageSettings.option == .photos }

    public var needsPhotosPermissionInThisApp: Bool {
        guard MediaStorageSettings.option == .photos else { return false }
        switch authorization.readWriteStatus {
        case .authorized, .limited: return false
        default: return true
        }
    }

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
        switch authorization.readWriteStatus {
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
                // The setting stays (or returns) in Luna after a declined
                // request, never claiming the unavailable Photos destination.
                chooseInLuna()
                completion(.refused)
                return
            }
            MediaStorageSettings.choose(.photos)
            completion(.granted)
        }
    }

    public func requestPhotosPermissionRelay(
        completion: @escaping (DownloadStoragePhotosOutcome) -> Void
    ) {
        switch authorization.readWriteStatus {
        case .authorized, .limited:
            completion(.granted)
            return
        case .denied, .restricted:
            // The setting is already Photos and stays that way — it is the
            // sibling app's answer, not this process's to revert — but this
            // process still cannot write there until Settings says otherwise.
            completion(.refusedBefore)
            return
        default:
            break
        }
        Task { @MainActor in
            guard await saver.requestReadAuthorization() else {
                completion(.refused)
                return
            }
            completion(.granted)
        }
    }
}
