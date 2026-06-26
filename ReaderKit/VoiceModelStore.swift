//
//  VoiceModelStore.swift
//  ReaderKit
//

import Foundation

/// Shared, App-Group-backed state for the multi-engine text-to-speech system:
/// the currently selected engine, the one-time first-run prompt flag, and the
/// on-disk location of downloaded neural models. Readable from BOTH the main app
/// and the extensions (they share `group.com.hpiddy.clip`).
///
/// Neural models live under `<AppGroup>/VoiceModels/<engine>/`. A model is
/// considered "downloaded" only when every file in its registry entry exists on
/// disk, so a half-finished download never reports as available.
enum VoiceModelStore {

    static let appGroupID = "group.com.hpiddy.clip"
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    private static let selectedEngineKey = "voiceSelectedEngine"
    private static let hasSeenVoicePromptKey = "hasSeenVoicePrompt"

    // MARK: - Selected engine

    /// The engine the user has chosen for read-aloud. Defaults to `.basic`.
    /// Setting it does NOT validate availability — callers select only available
    /// engines via the settings UI, and `SpeechController` falls back at play
    /// time if the stored engine is no longer usable.
    static var selectedEngine: VoiceEngineKind {
        get {
            VoiceEngineKind(rawValue: defaults.string(forKey: selectedEngineKey) ?? "")
                ?? .basic
        }
        set { defaults.set(newValue.rawValue, forKey: selectedEngineKey) }
    }

    /// Resets the selection to a safe, always-available engine. Called when the
    /// currently selected engine's model is deleted.
    static func resetSelectionToSafeDefault() {
        selectedEngine = .basic
    }

    // MARK: - First-run prompt

    /// Whether the one-time "choose a voice" prompt has been shown. Set the first
    /// time the user starts read-aloud.
    static var hasSeenVoicePrompt: Bool {
        get { defaults.bool(forKey: hasSeenVoicePromptKey) }
        set { defaults.set(newValue, forKey: hasSeenVoicePromptKey) }
    }

    // MARK: - Model file locations

    /// The App Group container, or `nil` if it can't be resolved (which would
    /// mean neural models are unavailable — engines then fall back).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// The directory holding the downloaded files for a neural engine.
    static func modelDirectory(for kind: VoiceEngineKind) -> URL? {
        guard kind.requiresDownload, let container = containerURL else { return nil }
        return container
            .appendingPathComponent("VoiceModels", isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// Ensures the model directory exists, returning its URL.
    @discardableResult
    static func ensureModelDirectory(for kind: VoiceEngineKind) -> URL? {
        guard let dir = modelDirectory(for: kind) else { return nil }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The on-disk path a given model file should live at.
    static func localURL(for file: VoiceModelFile, kind: VoiceEngineKind) -> URL? {
        modelDirectory(for: kind)?.appendingPathComponent(file.filename)
    }

    // MARK: - Availability

    /// Whether an engine is ready to be selected and used.
    ///
    /// - `basic`: always.
    /// - `appleEnhanced`: an enhanced/premium voice is installed.
    /// - `piper`/`kokoro`: every registry file is present on disk.
    static func isAvailable(_ kind: VoiceEngineKind) -> Bool {
        switch kind {
        case .basic:
            return true
        case .appleEnhanced:
            return AppleEnhancedEngine.hasInstalledEnhancedVoice
        case .piper, .kokoro:
            return isDownloaded(kind)
        }
    }

    /// Whether every file for a neural engine exists on disk.
    static func isDownloaded(_ kind: VoiceEngineKind) -> Bool {
        guard let files = VoiceModelRegistry.files(for: kind) else { return false }
        let fm = FileManager.default
        return files.allSatisfy { file in
            guard let url = localURL(for: file, kind: kind) else { return false }
            return fm.fileExists(atPath: url.path)
        }
    }

    /// Removes all downloaded files for a neural engine. If it was the selected
    /// engine, selection is reset to a safe default.
    static func deleteModel(for kind: VoiceEngineKind) {
        guard kind.requiresDownload, let dir = modelDirectory(for: kind) else { return }
        try? FileManager.default.removeItem(at: dir)
        if selectedEngine == kind {
            resetSelectionToSafeDefault()
        }
    }
}
