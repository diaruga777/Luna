import XCTest
@testable import LunaMusicCore

final class MusicQueueSnapshotTests: XCTestCase {
    private func snapshot() -> MusicQueueSnapshot {
        MusicQueueSnapshot(songIDs: [1, 2, 3, 4], currentIndex: 1, playbackTime: 25,
                           originalSongIDs: [4, 3, 2, 1], shuffleEnabled: true,
                           repeatMode: 0, sourcePlaylistName: "Favourites", sourcePlaylistID: 99)
    }
    func testSurvivingCurrentSongPreservesPositionAndState() {
        let restored = snapshot().resolving(availableIDs: [2, 3, 4])
        XCTAssertEqual(restored?.songIDs, [2, 3, 4])
        XCTAssertEqual(restored?.currentIndex, 0)
        XCTAssertEqual(restored?.playbackTime, 25)
        XCTAssertEqual(restored?.sourcePlaylistID, 99)
        XCTAssertEqual(restored?.originalSongIDs, [4, 3, 2])
    }
    func testDeletedCurrentSongAdvancesToNextSurvivor() {
        let restored = snapshot().resolving(availableIDs: [1, 3, 4])
        XCTAssertEqual(restored?.currentIndex, 1)
        XCTAssertEqual(restored?.songIDs[1], 3)
        XCTAssertEqual(restored?.playbackTime, 0)
    }
    func testEmptyLibraryDropsQueue() {
        XCTAssertNil(snapshot().resolving(availableIDs: []))
    }
    func testInvalidProgressIsSanitized() {
        var value = snapshot()
        value.playbackTime = .infinity
        XCTAssertEqual(value.resolving(availableIDs: [1, 2, 3, 4])?.playbackTime, 0)
    }
    func testCodableRoundTrip() throws {
        let value = snapshot()
        XCTAssertEqual(try JSONDecoder().decode(MusicQueueSnapshot.self, from: JSONEncoder().encode(value)), value)
    }
}
