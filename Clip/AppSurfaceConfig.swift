//
//  AppSurfaceConfig.swift
//  Clip
//

import ClipReadingListUI
import Foundation

/// Which standalone Quartz app this bundle is, derived from the bundle identifier
/// suffix (`com.hsanabria.quartz.<surface>`). The three apps share one codebase, one
/// App Group, and one shared store; this is the single switch that tells a running
/// process which content surface it presents.
///
/// Deriving from the bundle id keeps the apps a single source tree with no per-app
/// Swift or Info.plist branching — the only per-app input is the bundle id, which is
/// already driven by `Config/Quartz.xcconfig` + each app's `PRODUCT_BUNDLE_IDENTIFIER`.
enum AppSurfaceConfig {
    static var current: AppSurface {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        if identifier.hasSuffix(".downloader") { return .downloader }
        if identifier.hasSuffix(".pricetracker") { return .priceTracker }
        return .reader
    }
}
