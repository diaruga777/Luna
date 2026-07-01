//
//  AppEnvironment.swift
//  Luna
//

import Foundation

/// Runtime environment checks. `isSimulator` gates **simulator-only** test hooks
/// (extra tap targets / buttons that stand in for gestures the automation harness
/// can't synthesize, e.g. long-press context menus and card swipes). These hooks
/// must NEVER appear on device — always wrap them in `if AppEnvironment.isSimulator`.
public enum AppEnvironment {
    public static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
