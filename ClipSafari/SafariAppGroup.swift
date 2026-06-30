//
//  SafariAppGroup.swift
//  ClipSafari
//

import Foundation

/// The shared App Group identifier for the Safari web extension.
///
/// Mirrors `ClipAppConfig.AppConfig.appGroupID` for the one target that doesn't link the
/// package: the value is injected from `Config/Quartz.xcconfig` into this extension's
/// `Info.plist` as `QuartzAppGroupID` and read at runtime, so the namespace has a single
/// source of truth and renaming it stays a one-line xcconfig edit.
enum SafariAppGroup {
    static let id: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "QuartzAppGroupID") as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("$(") {
                return trimmed
            }
        }
        return "group.com.hsanabria.quartz"
    }()
}
