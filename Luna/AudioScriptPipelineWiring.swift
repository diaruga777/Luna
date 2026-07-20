//
//  AudioScriptPipelineWiring.swift
//  Luna
//

import LunaAudioPlayback
import Foundation

/// App-shell composition for Phase 4 of `claudedocs/audio-playback-plan.md`
/// (trimming): installed once at launch from `AppDelegate`, right after
/// `AudioPlaybackWiring` (whose `AppAudioPlaybackDataSource` already routes
/// `AudioPlaybackCenter.shared`'s script lookups through
/// `AudioScriptPipeline.shared`) — this call starts the pipeline's own
/// `.readingListChanged` observers/launch sweep. The Share/Action extensions
/// never call `install()`, so they never observe changes or run the builder
/// themselves.
enum AudioScriptPipelineWiring {

    static func install() {
        AudioScriptPipeline.shared.install()
    }
}
