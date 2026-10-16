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

// Layout regressions are exercised with media snapshots; no Apple account or
// writes to the user's music library are needed.
import UIKit
import MediaPlayer
@testable import LunaMusicUI

@MainActor
final class MusicLayoutTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }
    private func show(_ controller: UIViewController, category: UIContentSizeCategory = .large) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        controller.traitOverrides.preferredContentSizeCategory = category
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }
    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }
    private func capture(_ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testMiniPlayerFitsLargeTextAndHasSeparateTapTargets() {
        let screen = MusicScreenViewController()
        show(screen, category: .extraExtraExtraLarge)
        screen.mini.titleLabel.text = "Above And Below"
        screen.mini.artistLabel.text = "The Bravery"
        screen.view.layoutIfNeeded()
        let mini = screen.mini
        for (label, font) in [(mini.titleLabel as UIView, mini.titleLabel.font), (mini.artistLabel as UIView, mini.artistLabel.font!)] {
            let frame = label.convert(label.bounds, to: mini)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, mini.bounds.height)
            XCTAssertGreaterThanOrEqual(frame.height, font.lineHeight - 1)
        }
        let buttons = descendants(mini, of: UIButton.self)
        let open = buttons.first { $0.accessibilityLabel == "Open Now Playing" }!
        let play = buttons.first { $0.accessibilityLabel == "Play" || $0.accessibilityLabel == "Pause" }!
        let playFrame = play.convert(play.bounds, to: mini)
        XCTAssertFalse(open.convert(open.bounds, to: mini).intersects(playFrame))
        XCTAssertGreaterThanOrEqual(playFrame.height, 44)
        capture("Mini player at XXXL")
    }
    func testQueueModesDoNotOverlapHeaderAfterRepeatedLayouts() {
        let player = MusicPlayerViewController(showQueue: true)
        show(player, category: .extraExtraExtraLarge)
        for _ in 0..<5 { player.view.setNeedsLayout(); player.view.layoutIfNeeded() }
        let buttons = descendants(player.view, of: UIButton.self)
        let shuffle = buttons.first { $0.accessibilityLabel == "Shuffle" }!
        let title = descendants(player.view, of: UILabel.self).first { $0.text == "Not Playing" }!
        let artist = descendants(player.view, of: UILabel.self).first { $0.text == "Choose music from your library" }!
        let modes = shuffle.convert(shuffle.bounds, to: player.view)
        XCTAssertGreaterThan(modes.minY, artist.convert(artist.bounds, to: player.view).maxY)
        XCTAssertFalse(modes.intersects(title.convert(title.bounds, to: player.view)))
        capture("Queue at XXXL")
    }
    func testEmptyPlaylistMessageFollowsHeaderAndAddMusicIsReachable() {
        let playlist = LayoutPlaylist(items: [])
        let screen = MusicCollectionViewController(title: "Test Playlist", results: [], collection: .playlist(MusicPlaylist(playlist)))
        show(UINavigationController(rootViewController: screen))
        screen.view.layoutIfNeeded()
        let header = screen.table.tableHeaderView!
        let footer = screen.table.tableFooterView!
        XCTAssertGreaterThanOrEqual(footer.frame.minY, header.frame.maxY - 1)
        let button = descendants(header, of: UIButton.self).first { $0.accessibilityIdentifier == "music.playlist.addMusic" }!
        XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: screen.view)
        XCTAssertTrue(screen.view.hitTest(point, with: nil)?.isDescendant(of: button) == true)
        XCTAssertNotNil(screen.navigationItem.searchController)
        capture("Empty playlist with Add Music")
    }
    private func waitForRows(_ count: Int, in screen: MusicCollectionViewController) async throws {
        for _ in 0..<200 {
            if screen.tableView(screen.table, numberOfRowsInSection: 0) == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Collection search did not publish \(count) rows")
    }
    func testCollectionSearchFiltersAlbumsAndSongs() async throws {
        let first = LayoutSong(id: 1, title: "Drive", album: "Heartbeat City", artist: "The Cars")
        let second = LayoutSong(id: 2, title: "Hello", album: "Other Album", artist: "Another Artist")
        for result in [MusicResult.album(MusicCollection(items: [first, second].map(MusicSong.init))), .artist(MusicCollection(items: [first, second].map(MusicSong.init))), .playlist(MusicPlaylist(LayoutPlaylist(items: [first, second])))] {
            let rows: [MusicResult]
            if case .artist = result {
                rows = [.album(MusicCollection(items: [MusicSong(first)])), .album(MusicCollection(items: [MusicSong(second)]))]
            } else { rows = [.song(MusicSong(first)), .song(MusicSong(second))] }
            let screen = MusicCollectionViewController(title: result.name, results: rows, collection: result)
            show(UINavigationController(rootViewController: screen))
            let search = screen.navigationItem.searchController!
            XCTAssertTrue(screen.navigationItem.hidesSearchBarWhenScrolling)
            search.searchBar.text = "Cars"
            screen.updateSearchResults(for: search)
            try await waitForRows(1, in: screen)
            XCTAssertEqual(screen.tableView(screen.table, numberOfRowsInSection: 0), 1)
            search.searchBar.text = "No Match"
            screen.updateSearchResults(for: search)
            try await waitForRows(0, in: screen)
            XCTAssertEqual(screen.tableView(screen.table, numberOfRowsInSection: 0), 0)
            search.searchBar.text = ""
            screen.updateSearchResults(for: search)
            XCTAssertNotNil(screen.table.tableHeaderView)
        }
    }
    func testDownloadedFilterCombinesWithSearchAndKeepsCollectionMetadata() async throws {
        let local = MusicSong(LayoutSong(id: 1, title: "Drive", album: "Heartbeat City", artist: "The Cars"))
        let cloud = MusicSong(LayoutSong(id: 2, title: "Hello", album: "Other Album", artist: "Another Artist", cloud: true))
        let mixed = MusicResult.album(MusicCollection(items: [local, cloud]))
        let remote = MusicResult.album(MusicCollection(items: [cloud]))
        for (title, rows) in [("Songs", [MusicResult.song(local), .song(cloud)]), ("Artists", [.artist(MusicCollection(items: [local, cloud])), .artist(MusicCollection(items: [cloud]))]), ("Playlists", [.playlist(MusicPlaylist(LayoutPlaylist(items: [local.mediaItem!, cloud.mediaItem!]))), .playlist(MusicPlaylist(LayoutPlaylist(items: [cloud.mediaItem!])))]), ("Albums", [mixed, remote])] {
            let screen = MusicCollectionViewController(title: title, results: rows, downloadedOnly: true)
            screen.loadViewIfNeeded()
            XCTAssertEqual(screen.tableView(screen.table, numberOfRowsInSection: 0), 1)
            let search = screen.navigationItem.searchController!
            search.searchBar.text = "No Match"
            screen.updateSearchResults(for: search)
            try await waitForRows(0, in: screen)
            XCTAssertEqual(screen.tableView(screen.table, numberOfRowsInSection: 0), 0)
            search.searchBar.text = "Cars"
            screen.updateSearchResults(for: search)
            try await waitForRows(1, in: screen)
            XCTAssertEqual(screen.tableView(screen.table, numberOfRowsInSection: 0), 1)
            screen.downloadedOnly = false
            search.searchBar.text = ""
            screen.updateSearchResults(for: search)
            XCTAssertEqual(screen.tableView(screen.table, numberOfRowsInSection: 0), title == "Albums" ? 1 : 2)
        }
        XCTAssertEqual(mixed.songs.count, 2, "Filtering must not mutate the original collection")
        XCTAssertTrue(mixed.hasDownloadedSongs)
        XCTAssertFalse(remote.hasDownloadedSongs)
    }

    func testDownloadedFilterCarriesIntoAlbumDetailAndCanBeTurnedOff() {
        let songs = [MusicSong(LayoutSong(id: 1, title: "Drive", album: "Album", artist: "Artist")), MusicSong(LayoutSong(id: 2, title: "Cloud Song", album: "Album", artist: "Artist", cloud: true))]
        let owner = MusicScreenViewController()
        let navigation = UINavigationController(rootViewController: owner)
        MusicResult.album(MusicCollection(items: songs)).open(from: owner, downloadedOnly: true)
        let detail = navigation.topViewController as! MusicCollectionViewController
        detail.loadViewIfNeeded()
        XCTAssertTrue(detail.downloadedOnly)
        XCTAssertEqual(detail.tableView(detail.table, numberOfRowsInSection: 0), 1)
        detail.downloadedOnly = false
        XCTAssertEqual(detail.tableView(detail.table, numberOfRowsInSection: 0), 2)
    }

    func testPickerSelectionSurvivesDownloadedFilterChanges() async {
        let local = LayoutSong(id: 1, title: "Local", album: "Album", artist: "Artist")
        let cloud = LayoutSong(id: 2, title: "Remote", album: "Album", artist: "Artist", cloud: true)
        let saved = expectation(description: "Both selections preserved")
        let picker = MusicPlaylistSongPicker(playlist: MusicPlaylist(LayoutPlaylist(items: [])), songProvider: { [local, cloud].map(MusicSong.init) }) { items in
            XCTAssertEqual(items.map(\.persistentID), [1, 2])
            saved.fulfill()
        }
        show(UINavigationController(rootViewController: picker))
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        picker.downloadedOnly = true
        XCTAssertEqual(picker.tableView(picker.tableView, numberOfRowsInSection: 0), 1)
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(picker.navigationItem.rightBarButtonItem?.title, "Add (2)")
        picker.downloadedOnly = false
        XCTAssertEqual(picker.tableView(picker.tableView, numberOfRowsInSection: 0), 2)
        let button = UIButton()
        button.addAction(picker.navigationItem.rightBarButtonItem!.primaryAction!, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        await fulfillment(of: [saved], timeout: 3)
    }

    func testPlaylistPickerKeepsSelectionAcrossSearchAndSavesSelectedSongs() async {
        let songs = [LayoutSong(id: 1, title: "Drive", album: "Heartbeat City", artist: "The Cars"), LayoutSong(id: 2, title: "Hello", album: "Other Album", artist: "Another Artist")]
        let saved = expectation(description: "Selected songs sent to playlist API")
        let picker = MusicPlaylistSongPicker(playlist: MusicPlaylist(LayoutPlaylist(items: [])), songProvider: { songs.map(MusicSong.init) }) { items in
            XCTAssertEqual(items.map(\.persistentID), [1, 2])
            saved.fulfill()
        }
        show(UINavigationController(rootViewController: picker))
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        let search = picker.navigationItem.searchController!
        search.searchBar.text = "Hello"
        picker.updateSearchResults(for: search)
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(picker.navigationItem.rightBarButtonItem?.title, "Add (2)")
        search.searchBar.text = ""
        picker.updateSearchResults(for: search)
        XCTAssertEqual(picker.tableView(picker.tableView, cellForRowAt: IndexPath(row: 0, section: 0)).accessoryType, .checkmark)
        let action = picker.navigationItem.rightBarButtonItem!.primaryAction!
        // Invoke through the same action dispatched by the navigation bar.
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        await fulfillment(of: [saved], timeout: 3)
    }
}

private final class LayoutSong: MPMediaItem {
    private let id: UInt64
    private let songTitle: String
    private let album: String
    private let performer: String
    private let cloud: Bool
    init(id: UInt64, title: String, album: String, artist: String, cloud: Bool = false) {
        self.id = id; songTitle = title; self.album = album; performer = artist; self.cloud = cloud
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func value(forProperty property: String) -> Any? { nil }
    override var persistentID: MPMediaEntityPersistentID { id }
    override var albumPersistentID: MPMediaEntityPersistentID { id }
    override var isCloudItem: Bool { cloud }
    override var title: String? { songTitle }
    override var albumTitle: String? { album }
    override var artist: String? { performer }
}

private final class LayoutPlaylist: MPMediaPlaylist {
    private let storedItems: [MPMediaItem]
    override init(items: [MPMediaItem]) { storedItems = items; super.init(items: items) }
    required init?(coder: NSCoder) { fatalError() }
    override var items: [MPMediaItem] { storedItems }
    override var representativeItem: MPMediaItem? { storedItems.first }
    override func value(forProperty property: String) -> Any? { nil }
    override var persistentID: MPMediaEntityPersistentID { 42 }
    override var playlistAttributes: MPMediaPlaylistAttribute { [] }
    override var name: String? { "Test Playlist" }
}
