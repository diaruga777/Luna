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

final class FakePlaybackStore: ReadingListPlaybackStore {
    var itemsByID: [UUID: ReadingListItem] = [:]
    var contentsByID: [UUID: ArticleContent] = [:]
    var markedReadStates: [(itemID: UUID, state: ReadingListItem.ReadState)] = []
    var finishedIDs: [UUID] = []
    var spokenWordIndexWrites: [(itemID: UUID, wordIndex: Int)] = []

    func seed(_ item: ReadingListItem, content: ArticleContent?) {
        itemsByID[item.id] = item
        contentsByID[item.id] = content
    }

    func item(withID itemID: UUID) -> ReadingListItem? { itemsByID[itemID] }
    func content(for item: ReadingListItem) -> ArticleContent? { contentsByID[item.id] }
    func markReadState(_ newState: ReadingListItem.ReadState, for itemID: UUID) {
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
    var needsMoreAudioHandler: (() -> Void)?

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
}

final class FakeSessionCoordinator: AudioSessionControlling {
    var actionHandler: ((AudioSessionCoordinator.Action) -> Void)?
    private(set) var startCount = 0
    private(set) var activateCount = 0
    private(set) var deactivationsScheduled = 0

    func start() { startCount += 1 }
    func activate() { activateCount += 1 }
    func scheduleDeactivationAfterUserPause() { deactivationsScheduled += 1 }
}

/// Test double for `AudioPlaybackCenterDataSource`. `script(for:content:)`
/// mirrors the production pass-through default since no
/// `AudioPlaybackCenterTests` case customizes trimming; `nextCandidate()` is
/// driven directly by `nextCandidateResult`.
final class FakeAudioPlaybackDataSource: AudioPlaybackCenterDataSource {
    var nextCandidateResult: QueueCandidate?

    func nextCandidate() -> QueueCandidate? { nextCandidateResult }

    func script(for item: ReadingListItem, content: ArticleContent) -> AudioScript {
        AudioScript(passthrough: content)
    }

    func prefetch(item: ReadingListItem, content: ArticleContent) {}
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

    static func item(seed: String, title: String = "Fixture Article") -> ReadingListItem {
        ReadingListItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: title,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
