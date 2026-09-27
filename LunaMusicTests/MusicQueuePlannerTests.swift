import XCTest
@testable import LunaMusicCore

final class MusicQueuePlannerTests: XCTestCase {
    func testMostRecentlyPlayedContainingPlaylistWinsOverLargerPlaylist() {
        let older = MusicQueuePlanner.Playlist(id: 10, songIDs: [1, 2, 3, 4], lastPlayed: Date(timeIntervalSince1970: 1))
        let newer = MusicQueuePlanner.Playlist(id: 20, songIDs: [1, 5], lastPlayed: Date(timeIntervalSince1970: 2))
        let unrelated = MusicQueuePlanner.Playlist(id: 30, songIDs: [9], lastPlayed: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(MusicQueuePlanner.playlist(containing: 1, in: [older, unrelated, newer])?.id, 20)
    }

    func testUnplayedPlaylistCannotDisplacePlayedPlaylist() {
        let played = MusicQueuePlanner.Playlist(id: 10, songIDs: [1], lastPlayed: Date(timeIntervalSince1970: 1))
        let unplayed = MusicQueuePlanner.Playlist(id: 20, songIDs: [1, 2, 3, 4])
        XCTAssertEqual(MusicQueuePlanner.playlist(containing: 1, in: [unplayed, played])?.id, 10)
    }

    func testLargestContainingPlaylistWhenNoneHaveBeenPlayed() {
        let smaller = MusicQueuePlanner.Playlist(id: 10, songIDs: [1, 2])
        let larger = MusicQueuePlanner.Playlist(id: 20, songIDs: [1, 2, 3])
        XCTAssertEqual(MusicQueuePlanner.playlist(containing: 1, in: [smaller, larger])?.id, 20)
    }

    func testDuplicateSongsDoNotInflatePlaylistSize() {
        let duplicates = MusicQueuePlanner.Playlist(id: 10, songIDs: [1, 1, 1, 1])
        let larger = MusicQueuePlanner.Playlist(id: 20, songIDs: [1, 2])
        XCTAssertEqual(MusicQueuePlanner.playlist(containing: 1, in: [duplicates, larger])?.id, 20)
    }

    func testSelectionUsesStableIDToBreakTies() {
        let first = MusicQueuePlanner.Playlist(id: 10, songIDs: [1, 2])
        let second = MusicQueuePlanner.Playlist(id: 20, songIDs: [1, 3])
        XCTAssertEqual(MusicQueuePlanner.playlist(containing: 1, in: [second, first])?.id, 10)
    }

    func testSelectedSongAlwaysFirstAndRemainingSongsAppearOnce() {
        let playlist = MusicQueuePlanner.Playlist(id: 10, songIDs: [2, 1, 3, 1, 2, 4])
        var generator = SeededGenerator()
        for _ in 0..<20 {
            let queue = MusicQueuePlanner.songIDs(startingWith: 1, playlist: playlist, using: &generator)
            XCTAssertEqual(queue.first, 1)
            XCTAssertEqual(queue.count, 4)
            XCTAssertEqual(Set(queue), [1, 2, 3, 4])
        }
    }

    func testNoContainingPlaylistPlaysOnlySelectedSong() {
        let playlist = MusicQueuePlanner.Playlist(id: 10, songIDs: [2, 3])
        let selected = MusicQueuePlanner.playlist(containing: 1, in: [playlist])
        XCTAssertNil(selected)
        var generator = SeededGenerator()
        XCTAssertEqual(MusicQueuePlanner.songIDs(startingWith: 1, playlist: selected, using: &generator), [1])
    }

    func testEmptyLibraryPlaysOnlySelectedSong() {
        XCTAssertNil(MusicQueuePlanner.playlist(containing: 1, in: []))
        var generator = SeededGenerator()
        XCTAssertEqual(MusicQueuePlanner.songIDs(startingWith: 1, playlist: nil, using: &generator), [1])
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64 = 42
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
