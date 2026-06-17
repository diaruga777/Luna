//
//  ActionReaderMode.swift
//  ShareKit
//

import Foundation

/// The reader mode the "Read in Queue" ACTION extension last used. Persisted in
/// the extension's OWN `UserDefaults.standard` (its private container — NOT the
/// App Group, NOT the main app), so the action extension remembers its own
/// preference independently of the main-app reader.
enum ActionReaderMode {
    private static let key = "actionReaderMode"

    static var last: ShareReaderViewController.Mode {
        get {
            ShareReaderViewController.Mode(
                rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .reader
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
