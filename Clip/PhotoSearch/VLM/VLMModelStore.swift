//
//  VLMModelStore.swift
//  clipper
//

import Foundation

/// Persists which VLM the user selected. Backed by the App Group `UserDefaults`
/// suite (not `.standard`) so the background ingest extension reads the same
/// selection the app wrote.
protocol VLMModelStore: AnyObject, Sendable {
    var selectedModel: VLMModel { get set }
}

final class VLMModelStoreImpl: VLMModelStore, @unchecked Sendable {

    private static let key = "photoSearchVLMModel"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppGroup.id)
            ?? .standard
    }

    var selectedModel: VLMModel {
        get {
            guard
                let raw = defaults.string(forKey: Self.key),
                let model = VLMModel(rawValue: raw)
            else {
                return .defaultModel
            }
            return model
        }
        set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
