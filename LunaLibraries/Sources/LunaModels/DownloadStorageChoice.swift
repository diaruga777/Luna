//
//  DownloadStorageChoice.swift
//  LunaModels
//

import Foundation

/// How the Photos leg of a "store downloads in Photos" request ended.
public enum DownloadStoragePhotosOutcome: Equatable, Sendable {
    /// Photos may be written to; the setting has been saved.
    case granted
    /// The user refused the system prompt. The setting stayed/reverted to Luna.
    case refused
    /// The user had already refused, so iOS will not prompt again — the only way
    /// through is the app's own page in system Settings.
    case refusedBefore
}

/// The util card's inline "Store downloads …" choice, implemented by the media
/// module and installed by the `KindWiring` of each app that downloads.
///
/// The util card lives in the universal app shell, so it cannot name
/// `MediaStorageSettings` — the two apps with no media module must not even be
/// able to offer the row. This is the seam: `DownloadStorageChoice.installed`
/// is nil in Reader and Price Tracker, and the card asks nothing further.
@MainActor
public protocol DownloadStorageChoosing: AnyObject {
    /// Whether the user has yet made this choice themselves — here or in
    /// Settings → Downloads. The card offers the row only while they have not.
    var isUnanswered: Bool { get }
    /// The choice as it stands, which on a fresh install is the shipped default
    /// rather than anything the user has said.
    var usesPhotos: Bool { get }
    /// Stores downloads in Luna, under the deletion clock.
    func chooseInLuna()
    /// Asks for Photos access FIRST and saves the setting only if it is granted:
    /// "store downloads in Photos" without the permission that makes it possible
    /// is a setting that silently does something else.
    ///
    /// Every outcome counts as the user having ANSWERED — a refusal is an answer
    /// — so the row is retired from the next launch either way.
    func choosePhotos(completion: @escaping (DownloadStoragePhotosOutcome) -> Void)
}

/// Where the installed chooser lives. One per process, set at launch.
@MainActor
public enum DownloadStorageChoice {
    public static var installed: (any DownloadStorageChoosing)?
}
