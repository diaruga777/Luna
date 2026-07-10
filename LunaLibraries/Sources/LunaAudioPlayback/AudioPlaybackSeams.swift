//
//  AudioPlaybackSeams.swift
//  LunaAudioPlayback
//

import AVFoundation
import LunaModels
import LunaStorage

/// A candidate for autoplay: a not-yet-opened, readable Reader-surface article
/// plus its already-loaded `ArticleContent`, bundled together so
/// `AudioPlaybackCenter` never has to re-hit the store to start playing it.
/// Built by the app shell's `AudioPlaybackCenter.nextItemProvider` closure,
/// which reuses the exact ordering `ReadingListSectioning`/
/// `ReadingListViewController` display for the Reader surface — see
/// `claudedocs/audio-playback-plan.md`.
public struct QueueCandidate {
    public var item: ReadingListItem
    public var content: ArticleContent

    public init(item: ReadingListItem, content: ArticleContent) {
        self.item = item
        self.content = content
    }
}

/// The narrow slice of `LunaStorage.ReadingListStore` that `AudioPlaybackCenter`
/// needs, kept as a protocol so tests can substitute an in-memory fake instead
/// of a real App-Group-backed store. `ReadingListStore` conforms below purely
/// structurally (no code change needed there).
public protocol ReadingListPlaybackStore: AnyObject {
    func item(withID itemID: UUID) -> ReadingListItem?
    func content(for item: ReadingListItem) -> ArticleContent?
    func markReadState(_ newState: ReadingListItem.ReadState, for itemID: UUID)
    func markFinishedReading(_ itemID: UUID)
    func setLastSpokenWordIndex(_ wordIndex: Int, for itemID: UUID)
}

extension ReadingListStore: ReadingListPlaybackStore {}

/// The slice of `SpeechRenderer` `AudioPlaybackCenter` drives, kept as a
/// protocol so tests can substitute a fake that returns canned
/// `RenderedSegment`s instantly instead of driving real offline
/// `AVSpeechSynthesizer` synthesis.
public protocol SpeechRendering: AnyObject {
    var canonicalFormat: AVAudioFormat? { get }
    func render(_ block: AudioScript.SpokenBlock) async throws -> RenderedSegment
}

extension SpeechRenderer: SpeechRendering {}

/// The slice of `ArticleAudioEngine` `AudioPlaybackCenter` drives, kept as a
/// protocol so tests can substitute a fake playback graph instead of a real
/// `AVAudioEngine`.
public protocol ArticleAudioEngineControlling: AnyObject {
    var rate: Float { get set }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var needsMoreAudioHandler: (() -> Void)? { get set }

    func play()
    func pause()
    func stop()
    func resetAndSchedule(from time: TimeInterval)
    func schedule(_ segment: RenderedSegment, rateMode: SegmentRateMode, completion: (() -> Void)?)
    func scheduleTone(_ asset: ToneAsset, completion: (() -> Void)?) throws
}

extension ArticleAudioEngine: ArticleAudioEngineControlling {}

/// The slice of `AudioSessionCoordinator` `AudioPlaybackCenter` drives, kept as
/// a protocol so tests can substitute a no-op fake instead of touching a real
/// `AVAudioSession`/`NotificationCenter`.
public protocol AudioSessionControlling: AnyObject {
    var actionHandler: ((AudioSessionCoordinator.Action) -> Void)? { get set }
    func start()
    func activate()
    func scheduleDeactivationAfterUserPause()
}

extension AudioSessionCoordinator: AudioSessionControlling {}
