//
//  ActionReaderMode.swift
//  ShareKit
//

import Foundation

/// The reader mode the "Read in Luna" action extension used last.
///
/// This value lives in the extension's own `UserDefaults.standard`, not the
/// App Group and not the main app. The action extension keeps its own
/// preference, separate from the main app's reader.
public enum ActionReaderMode {
    private static let key = "actionReaderMode"

    public static var last: ExtensionReaderMode {
        get {
            ExtensionReaderMode(
                rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .reader
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
