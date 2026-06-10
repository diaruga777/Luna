//
//  Storage.swift
//  Clip
//
//  App Group container access. The feature only needs the shared container URL
//  and the group id for UserDefaults.
//

import Foundation

/// The app's shared App Group, used to store the photo index and downloaded
/// models so the background photo-upload extension can read them too.
enum AppGroup {
    static let id = "group.com.hpiddy.clip"

    /// Shared container URL, or nil if the entitlement isn't provisioned (callers
    /// fall back to Application Support).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
}
