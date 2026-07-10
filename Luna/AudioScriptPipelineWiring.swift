//
//  AudioScriptPipelineWiring.swift
//  Luna
//

import LunaAudioPlayback
import Foundation

/// App-shell composition for Phase 4 of `claudedocs/audio-playback-plan.md`
/// (trimming): installed once at launch from `AppDelegate`, in all three
/// Luna apps — same universal-machinery pattern as `AudioPlaybackWiring`.
/// The Share/Action extensions never call `install()`, so they never observe
/// `.readingListChanged` or run the builder themselves.
enum AudioScriptPipelineWiring {

    static func install() {
        AudioScriptPipeline.shared.install()
        AudioPlaybackCenter.shared.scriptProvider = { item, content in
            AudioScriptPipeline.shared.script(for: item, content: content)
        }
        AudioPlaybackCenter.shared.scriptPrefetchHandler = { item, content in
            AudioScriptPipeline.shared.prefetch(item: item, content: content)
        }
    }
}
