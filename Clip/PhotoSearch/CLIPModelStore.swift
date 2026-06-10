//
//  CLIPModelStore.swift
//  clipper
//

import Foundation

/// Persists the user's selected on-device photo-search embedding model.
protocol CLIPModelStore: AnyObject, Sendable {
    var selectedModel: CLIPModel { get set }
}

/// `UserDefaults`-backed selection store. Defaults to the bundled MobileCLIP2-S0
/// (newest, no download). Falls back to nothing else here — if its bundled
/// weights aren't present, the picker surfaces it as unavailable.
final class CLIPModelStoreImpl: CLIPModelStore {

    private let defaults: UserDefaults
    private let key = "photoSearchClipModel"

    /// Defaults to the App Group suite (not `.standard`) so the background ingest
    /// extension reads the same selection the app wrote.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppGroup.id)
            ?? .standard
    }

    var selectedModel: CLIPModel {
        get {
            guard
                let raw = defaults.string(forKey: key),
                let model = CLIPModel(rawValue: raw)
            else {
                return .mobileCLIP2S0
            }
            return model
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}
