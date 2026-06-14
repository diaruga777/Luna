//
//  ChunkHighlightController.swift
//  Clip
//

import Foundation

/// Receives chunk-level progress from the chunk-highlight reader.
protocol ChunkHighlightControllerDelegate: AnyObject {
    /// Highlight the chunk at `range` (its first word is `wordIndex`).
    func chunkHighlight(_ controller: ChunkHighlightController, willHighlight range: NSRange, wordIndex: Int)
    /// Play/pause state changed.
    func chunkHighlightStateDidChange(_ controller: ChunkHighlightController)
    /// Reached the end of the article.
    func chunkHighlightDidFinish(_ controller: ChunkHighlightController)
}

/// Timer-driven "chunk reading": walks the article highlighting a few words at
/// a time at a WPM-derived pace (no audio). Mirrors `SpeechController`'s control
/// surface so the scroll reader can drive highlighting/scrolling/footer
/// uniformly for both.
final class ChunkHighlightController {

    weak var delegate: ChunkHighlightControllerDelegate?

    private let chunks: [TextChunk]
    private(set) var isPlaying = false
    private var currentChunk = 0
    private var timer: Timer?

    /// WPM steps shown on the footer's speed button.
    private static let speedSteps: [Double] = [200, 300, 400, 500, 700]

    init(content: ArticleContent, wordMap: WordMap) {
        let words = RSVPEngine(content: content).words
        self.chunks = ChunkPlanner.chunks(words: words, wordRanges: wordMap.wordRanges)
    }

    deinit { timer?.invalidate() }

    /// First word index of the current chunk (shared word-index space).
    var currentWordIndex: Int? {
        chunks[safe: currentChunk]?.wordRange.lowerBound
    }

    var speedLabel: String { "\(Int(ReaderSettings.baseWPM))" }

    func play(fromWordIndex wordIndex: Int?) {
        guard !chunks.isEmpty else { return }
        if let wordIndex,
           let index = chunks.firstIndex(where: { $0.wordRange.contains(wordIndex) }) {
            currentChunk = index
        } else if currentChunk >= chunks.count {
            currentChunk = 0
        }
        isPlaying = true
        delegate?.chunkHighlightStateDidChange(self)
        showCurrent()
        scheduleNext()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play(fromWordIndex: currentWordIndex) }
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        delegate?.chunkHighlightStateDidChange(self)
    }

    func stop() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    /// Jumps to the first chunk of the next paragraph.
    func skipForward() {
        guard let paragraphEnd = chunks[currentChunk...].firstIndex(where: { $0.endsParagraph }),
              paragraphEnd + 1 < chunks.count else { return }
        seek(to: paragraphEnd + 1)
    }

    /// Jumps to the start of the current paragraph, or the previous one.
    func skipBackward() {
        // Walk back to the chunk after the previous paragraph end.
        var index = currentChunk - 1
        while index > 0, !chunks[index - 1].endsParagraph { index -= 1 }
        seek(to: max(0, index))
    }

    func cycleSpeed() {
        let steps = Self.speedSteps
        let current = ReaderSettings.baseWPM
        let next = steps.first(where: { $0 > current }) ?? steps[0]
        ReaderSettings.baseWPM = next
        delegate?.chunkHighlightStateDidChange(self)
        if isPlaying { scheduleNext() }
    }

    // MARK: - Private

    private func seek(to index: Int) {
        currentChunk = min(max(0, index), max(0, chunks.count - 1))
        showCurrent()
        if isPlaying { scheduleNext() } else { delegate?.chunkHighlightStateDidChange(self) }
    }

    private func showCurrent() {
        guard let chunk = chunks[safe: currentChunk] else { return }
        delegate?.chunkHighlight(
            self, willHighlight: chunk.characterRange, wordIndex: chunk.wordRange.lowerBound)
    }

    private func scheduleNext() {
        timer?.invalidate()
        guard let chunk = chunks[safe: currentChunk] else { return }
        let interval = ChunkPlanner.duration(for: chunk, wpm: ReaderSettings.baseWPM)
        timer = Timer.scheduledTimer(withTimeInterval: max(0.08, interval), repeats: false) {
            [weak self] _ in self?.advance()
        }
    }

    private func advance() {
        guard isPlaying else { return }
        guard currentChunk + 1 < chunks.count else {
            isPlaying = false
            delegate?.chunkHighlightDidFinish(self)
            delegate?.chunkHighlightStateDidChange(self)
            return
        }
        currentChunk += 1
        showCurrent()
        scheduleNext()
    }
}
