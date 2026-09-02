//
//  SaveReadiness.swift
//  LunaModels
//

import Foundation

/// Told when a save gains the content a destination would deliver.
///
/// The one production conformer wraps `ArticleSendCoordinator` (LunaSend), so
/// the witness is installed by the app shell's article leg rather than reached
/// directly. It stays nil in the two apps that link no send tier (Downloader,
/// Price Tracker) and in every extension, where a readiness report is a no-op.
public protocol SaveReadinessObserving {
    func saveBecameReady(_ item: SavedItem)
}

/// Where that observer is installed.
///
/// It lives in LunaModels because every reporter is BELOW the send tier and
/// none of them can see each other: the ingestor and the mail importer
/// (LunaSaves), article persistence (LunaReaderUI), a landed media download
/// (LunaMediaDownload) and a new price tracker (LunaPriceUI). One registry is
/// what makes those five reports one readiness path.
public enum SaveReadiness {
    public static var observer: (any SaveReadinessObserving)?
}
