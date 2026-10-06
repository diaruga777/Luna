import XCTest
import LunaMusicFiles
import LunaVaultMacPeer
import LunaVaultBEP

final class MusicFileTests: XCTestCase {
    func testSourceQualifiedIdentityAndLegacyDecoding() throws {
        XCTAssertNotEqual(MusicID("vault:42"), MusicID(integerLiteral: 42))
        XCTAssertEqual(try JSONDecoder().decode(MusicID.self, from: Data("42".utf8)), 42)
    }
    func testPlaylistRejectsOtherSourcesAndPersistsOrder() throws {
        var state = VaultMusicState(); state.peer = "mac"
        state.files = [file("a"), file("b")]
        let ids = state.files.map { $0.id(peer: state.peer) }
        XCTAssertThrowsError(try state.createPlaylist(name: "Mixed", songIDs: [ids[0], 1]))
        XCTAssertThrowsError(try state.createPlaylist(name: " ", songIDs: []))
        let playlist = try state.createPlaylist(name: " Offline ", songIDs: [ids[1], ids[0], ids[1]])
        XCTAssertEqual(playlist.songIDs, [ids[1], ids[0]])
        let restored = try JSONDecoder().decode(VaultMusicState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.playlists.first, playlist)
        XCTAssertEqual(restored.automaticPlaylistCount, 3)
    }
    func testAutoCacheRanksUsageAndPreservesManualPinsAndExclusions() {
        var state = VaultMusicState()
        for index in 0..<12 {
            var playlist = VaultMusicPlaylist(name: "\(index)", songIDs: [MusicID("vault:\(index)")])
            playlist.playCount = index
            state.playlists.append(playlist)
        }
        XCTAssertEqual(state.automaticIDs, Set([9, 10, 11].map { MusicID("vault:\($0)") }))
        state.excluded = [MusicID("vault:11")]; state.manual = [MusicID("vault:1")]
        XCTAssertEqual(state.desiredIDs, Set([1, 9, 10].map { MusicID("vault:\($0)") }))
        state.automaticPlaylistCount = 0
        XCTAssertEqual(state.desiredIDs, state.manual)
        state.automaticPlaylistCount = 100
        XCTAssertEqual(state.automaticIDs.count, 9) // capped at ten; one suppressed
    }
    func testArtistNormalization() {
        XCTAssertEqual(MusicFileProtocol.normalized(" Beyoncé "), MusicFileProtocol.normalized("BEYONCE"))
    }
    func testCatalogPicksUpFilesAndReadsVersionCheckedRanges() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Music/Artist/Album/01 Song.wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = wave(); try data.write(to: url)
        let library = CompanionMusicLibrary(vaultRoot: root, scanInterval: 0)
        let catalog = try await library.perform(.init(.catalog))
        XCTAssertEqual(catalog.files.count, 1)
        let song = try XCTUnwrap(catalog.files.first)
        XCTAssertEqual(song.artist, "Artist"); XCTAssertEqual(song.album, "Album")
        XCTAssertEqual(song.title, "01 Song"); XCTAssertEqual(song.track, 1)
        XCTAssertGreaterThan(song.duration, 0)
        let reply = try await library.perform(.init(.read, path: song.path, version: song.version, offset: 10, length: 50))
        XCTAssertEqual(reply.data, data.subdata(in: 10..<60))
        var replaced = data; replaced.append(0); try replaced.write(to: url)
        do { _ = try await library.perform(.init(.read, path: song.path, version: song.version, length: 40)); XCTFail("Stale version accepted") } catch {}
        try FileManager.default.removeItem(at: url)
        let empty = try await library.perform(.init(.catalog))
        XCTAssertTrue(empty.files.isEmpty)
    }
    func testTraversalAndSymlinksAreRejected() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.wav"); try wave().write(to: outside)
        let album = root.appendingPathComponent("Music/Artist/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: album.appendingPathComponent("link.wav"), withDestinationURL: outside)
        let library = CompanionMusicLibrary(vaultRoot: root)
        let catalog = try await library.perform(.init(.catalog))
        XCTAssertTrue(catalog.files.isEmpty)
        for path in ["../../outside.wav", "/outside.wav", "Artist/Album/link.wav"] {
            do { _ = try await library.perform(.init(.read, path: path, length: 4)); XCTFail("Unsafe path accepted") } catch {}
        }
    }
    func testPaginationUsesStableCatalogGeneration() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let album = root.appendingPathComponent("Music/Artist/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        for i in 0..<103 { try wave().write(to: album.appendingPathComponent("\(i).wav")) }
        let library = CompanionMusicLibrary(vaultRoot: root)
        let first = try await library.perform(.init(.catalog))
        XCTAssertEqual(first.files.count, 100)
        let second = try await library.perform(.init(.catalog, offset: 100, generation: first.generation))
        XCTAssertEqual(second.files.count, 3); XCTAssertNil(second.nextOffset)
        do { _ = try await library.perform(.init(.catalog, offset: 100, generation: "old")); XCTFail("Stale page accepted") } catch {}
    }
    private func file(_ path: String) -> MusicFile { MusicFile(path: "Artist/Album/\(path).mp3", version: "v1", size: 100, title: path, artist: "Artist", album: "Album") }
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func wave() -> Data {
        var data = Data()
        func text(_ s: String) { data.append(Data(s.utf8)) }
        func word(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func number(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); number(36 + 16000); text("WAVEfmt "); number(16); word(1); word(1)
        number(8000); number(16000); word(2); word(16); text("data"); number(16000)
        data.append(Data(count: 16000)); return data
    }
}
