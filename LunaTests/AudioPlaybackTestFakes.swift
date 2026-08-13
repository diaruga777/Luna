//
//  AudioPlaybackTestFakes.swift
//  LunaTests
//

import AVFoundation
import LunaModels
@testable import LunaAudioPlayback

/// Shared fakes behind `LunaAudioPlayback`'s seam protocols
/// (`AudioPlaybackSeams.swift`), used by `AudioPlaybackCenterTests` and
/// `NowPlayingCoordinatorTests` to exercise the center's state-machine /
/// queue / autoplay / persistence logic without real
/// `AVSpeechSynthesizer`/`AVAudioEngine`/`AVAudioSession` involvement.

final class FakePlaybackStore: SavesPlaybackStore {
    var itemsByID: [UUID: SavedItem] = [:]
    var contentsByID: [UUID: ArticleContent] = [:]
    var markedReadStates: [(itemID: UUID, state: SavedItem.ReadState)] = []
    var finishedIDs: [UUID] = []
    var spokenWordIndexWrites: [(itemID: UUID, wordIndex: Int)] = []

    func seed(_ item: SavedItem, content: ArticleContent?) {
        itemsByID[item.id] = item
        contentsByID[item.id] = content
    }

    func item(withID itemID: UUID) -> SavedItem? { itemsByID[itemID] }
    func content(for item: SavedItem) -> ArticleContent? { contentsByID[item.id] }
    func markReadState(_ newState: SavedItem.ReadState, for itemID: UUID) {
        markedReadStates.append((itemID, newState))
    }
    func markFinishedReading(_ itemID: UUID) { finishedIDs.append(itemID) }
    func setLastSpokenWordIndex(_ wordIndex: Int, for itemID: UUID) {
        spokenWordIndexWrites.append((itemID, wordIndex))
    }
}

/// Renders instantly: each block becomes a zero-buffer segment whose
/// duration is `secondsPerWord` x its word count (deterministic input for
/// the center's avg-sec-per-word math). Records every block rendered.
final class FakeRenderer: SpeechRendering {
    let canonicalFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)
    var secondsPerWord: TimeInterval = 0.25
    private(set) var renderedBlocks: [AudioScript.SpokenBlock] = []

    func render(_ block: AudioScript.SpokenBlock) async throws -> RenderedSegment {
        renderedBlocks.append(block)
        let words = block.text.split(whereSeparator: { $0.isWhitespace }).count
        return RenderedSegment(
            blockIndex: block.blockIndex, buffers: [], wordMarkers: [],
            duration: Double(words) * secondsPerWord, format: canonicalFormat!)
    }
}

/// Records scheduling calls; playback progress is driven manually by tests
/// firing the recorded completions (simulating "this segment has been fully
/// heard").
final class FakeAudioEngine: ArticleAudioEngineControlling {
    var rate: Float = 1.0
    private(set) var isPlaying = true
    var currentTime: TimeInterval = 0
    weak var delegate: ArticleAudioEngineDelegate?

    private(set) var scheduledSegments: [(segment: RenderedSegment, rateMode: SegmentRateMode, completion: (() -> Void)?)] = []
    private(set) var scheduledTones: [(asset: ToneAsset, completion: (() -> Void)?)] = []
    private(set) var pauseCount = 0

    func play() { isPlaying = true }
    func pause() { isPlaying = false; pauseCount += 1 }
    func resetAndSchedule(from time: TimeInterval) {
        currentTime = time
        isPlaying = true
    }
    func schedule(_ segment: RenderedSegment, rateMode: SegmentRateMode, completion: (() -> Void)?) {
        scheduledSegments.append((segment, rateMode, completion))
    }
    func scheduleTone(_ asset: ToneAsset, completion: (() -> Void)?) throws {
        scheduledTones.append((asset, completion))
    }

    // MARK: Test drivers

    /// Fires the completion of the scheduled segment at `index` (i.e. "the
    /// listener has now heard all of it").
    func completeSegment(at index: Int) {
        scheduledSegments[index].completion?()
    }

    func completeTone(at index: Int) {
        scheduledTones[index].completion?()
    }

    /// Reports the low-water mark the real engine trips when its queue drains.
    func signalNeedsMoreAudio() {
        delegate?.articleAudioEngineNeedsMoreAudio(self)
    }
}

final class FakeSessionCoordinator: AudioSessionControlling {
    weak var delegate: AudioSessionCoordinatorDelegate?
    private(set) var startCount = 0
    private(set) var activateCount = 0
    private(set) var deactivationsScheduled = 0

    func start() { startCount += 1 }
    func activate() { activateCount += 1 }
    func scheduleDeactivationAfterUserPause() { deactivationsScheduled += 1 }

    /// Reports an interruption/route-change decision, as the real coordinator
    /// does from its notification observers.
    func request(_ action: AudioSessionCoordinator.Action) {
        delegate?.audioSession(self, didRequest: action)
    }
}

/// Test double for `AudioPlaybackCenterDataSource`. `script(for:content:)`
/// mirrors the production pass-through default since no
/// `AudioPlaybackCenterTests` case customizes trimming; `nextCandidate()` is
/// driven directly by `nextCandidateResult`.
final class FakeAudioPlaybackDataSource: AudioPlaybackCenterDataSource {
    var nextCandidateResult: QueueCandidate?

    func nextCandidate() -> QueueCandidate? { nextCandidateResult }

    func script(for item: SavedItem, content: ArticleContent) -> AudioScript {
        AudioScript(passthrough: content)
    }

    func prefetch(item: SavedItem, content: ArticleContent) {}
}

// MARK: - Fixture helpers

enum AudioPlaybackFixtures {
    /// An `ArticleContent` of `blockCount` paragraphs, each exactly
    /// `wordsPerBlock` words — deterministic word-index geometry (block N
    /// starts at global word index N x wordsPerBlock).
    static func content(title: String = "Fixture Article", blockCount: Int, wordsPerBlock: Int = 4) -> ArticleContent {
        let blocks = (0..<blockCount).map { blockIndex in
            ArticleContent.Block(
                kind: .paragraph,
                text: (0..<wordsPerBlock).map { "w\(blockIndex)x\($0)" }.joined(separator: " "),
                links: [])
        }
        return ArticleContent(title: title, blocks: blocks)
    }

    static func item(seed: String, title: String = "Fixture Article") -> SavedItem {
        SavedItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: title,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

/// Hands out ONE prepared graph however many times the center asks. The fake
/// engine is a class, so a test can drive and inspect the same instance the
/// center is scheduling into.
final class FixedAudioEngineMaker: ArticleAudioEngineMaking {
    let engine: ArticleAudioEngineControlling

    init(_ engine: ArticleAudioEngineControlling) { self.engine = engine }

    func makeEngine(format: AVAudioFormat) throws -> ArticleAudioEngineControlling {
        engine
    }
}

/// Hands out ONE prepared trim session, so a test can script its responses and
/// then read back what it was asked.
final class FixedTrimModelSessionMaker: AudioTrimModelSessionMaking {
    let session: AudioTrimModelSession

    init(_ session: AudioTrimModelSession) { self.session = session }

    func makeSession() -> AudioTrimModelSession { session }
}

/// No artwork on disk for anything — these tests are about the rest of the Now
/// Playing info assembly.
struct NoStoredArtwork: NowPlayingArtworkProviding {
    func artworkFileURL(forFileName fileName: String) -> URL? { nil }
}
