import XCTest
import AVKit
import UIKit
import LunaVaultBEP
import LunaVaultStore
import LunaVaultSync
import LunaVaultUI

private actor VideoReadSpy {
    var ranges: [(Int64, Int)] = []
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    func read(_ offset: Int64, _ length: Int) -> Data {
        ranges.append((offset, length))
        return bytes.subdata(in: Int(offset)..<(Int(offset) + length))
    }
}

final class VaultVideoMetadataTests: XCTestCase {
    func testEpisodeFormatsAndSeasonRollover() {
        let pairs = [
            ("Show.Name.S01E02.Pilot.mp4", "Show.Name.S01E03.Next.mp4"),
            ("Show Name 1x02.mp4", "Show Name 1x03.mp4"),
            ("Show Name Season 1 Episode 02.mp4", "Show Name Season 1 Episode 03.mp4"),
            ("Show Name Ep 02.mp4", "Show Name Episode 03.mp4"),
            ("02 - Show Name.mp4", "03 - Show Name.mp4"),
            ("02 - Andor - Pilot.mp4", "03 - Andor - Next.mp4"),
            ("Andor02.mp4", "Andor03.mp4"),
            ("Show Name - 002 - Pilot.mp4", "Show Name - 003 - Next.mp4"),
            ("Show Name S01E10.mp4", "Show Name S02E01.mp4")
        ]
        for (current, next) in pairs {
            XCTAssertEqual(VaultVideoEpisodes.next(after: "Shows/" + current, siblings: ["Shows/" + next]), "Shows/" + next, current)
        }
    }
    func testNearestEpisodeRejectsOtherFoldersShowsAndReleaseNumbers() {
        let current = "TV/Star Trek S01E02 1080p.mp4"
        let candidates = ["TV/Star Trek S01E09.mp4", "TV/Star Wars S01E03.mp4", "Other/Star Trek S01E03.mp4",
                          "TV/Star Trek S01E01.mp4", "TV/Star Trek S01E03.txt", "TV/Star Trek S01E04.mp4"]
        XCTAssertEqual(VaultVideoEpisodes.next(after: current, siblings: candidates), "TV/Star Trek S01E04.mp4")
        XCTAssertNil(VaultVideoEpisodes.next(after: "Film 2025 1080p.mp4", siblings: ["Film 2026 2160p.mp4"]))
        XCTAssertNil(VaultVideoEpisodes.next(after: "Pilot.mp4", siblings: ["Episode 2.mp4"]))
    }
    func testNextCardTimingBoundariesAndInvalidTimes() {
        XCTAssertFalse(VaultVideoEpisodes.showsNext(seconds: 419, duration: 600, paused: true))
        XCTAssertTrue(VaultVideoEpisodes.showsNext(seconds: 420, duration: 600, paused: true))
        XCTAssertFalse(VaultVideoEpisodes.showsNext(seconds: 539, duration: 600, paused: false))
        XCTAssertTrue(VaultVideoEpisodes.showsNext(seconds: 540, duration: 600, paused: false))
        XCTAssertTrue(VaultVideoEpisodes.showsNext(seconds: 600, duration: 600, paused: true))
        XCTAssertFalse(VaultVideoEpisodes.showsNext(seconds: .nan, duration: 600, paused: true))
        XCTAssertFalse(VaultVideoEpisodes.showsNext(seconds: 10, duration: .infinity, paused: true))
    }
    func testHistorySurvivesReopeningAndKeepsFilesAndPeersSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = "mac/vault/Show S01E01.mp4"
        do {
            let history = VaultVideoHistory(store: try VaultFolderStore(rootURL: root))
            try history.save(VaultVideoProgress(seconds: 7321, duration: 14400), for: identity)
            try history.save(VaultVideoProgress(seconds: .nan, duration: 14400), for: identity)
        }
        let history = VaultVideoHistory(store: try VaultFolderStore(rootURL: root))
        XCTAssertEqual(try history.progress(for: identity)?.resumeSeconds, 7321)
        XCTAssertNil(try history.progress(for: "mac/vault/Show S01E02.mp4"))
        XCTAssertNil(try history.progress(for: "otherMac/vault/Show S01E01.mp4"))
        try history.save(VaultVideoProgress(seconds: 14400, duration: 14400, completed: true), for: identity)
        XCTAssertEqual(try history.progress(for: identity)?.resumeSeconds, 0)
    }
}


@MainActor
final class VaultVideoPlayerTests: XCTestCase {
    private var window: UIWindow?
    private var temporaryRoot: URL?
    private weak var temporaryStore: VaultFolderStore?
    override func tearDown() async throws {
        window?.rootViewController = nil; window?.isHidden = true; window = nil
        // UIKit/AVFoundation can retain dismissed players beyond teardown.
        // Never unlink a live SQLite database; remaining tmp data is OS-owned.
        for _ in 0..<10 where temporaryStore != nil { try await Task.sleep(for: .milliseconds(50)) }
        if temporaryStore == nil, let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
        try await super.tearDown()
    }
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vault-episodes", withExtension: "mp4"))
    }
    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { XCTFail("Player timed out"); throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func host(_ controller: UIViewController) throws {
        window?.rootViewController = nil; window?.isHidden = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); self.window = window
        window.rootViewController = controller; window.makeKeyAndVisible(); controller.loadViewIfNeeded()
    }
    private func nextButton(_ view: UIView) -> UIButton? {
        if view.accessibilityIdentifier == "vault.video.nextEpisode" { return view as? UIButton }
        return view.subviews.lazy.compactMap { self.nextButton($0) }.first
    }
    func testRemoteAssetLoadsTailMetadataWithoutDownloadAndSeeks() async throws {
        let bytes = try Data(contentsOf: fixture())
        let spy = VideoReadSpy(bytes)
        let source = VaultMediaSource(identity: "remote", name: "Show S01E01.mp4", size: Int64(bytes.count)) {
            await spy.read($0, $1)
        }
        let loader = VaultVideoResourceLoader(source: source)
        let duration = try await loader.asset.load(.duration)
        XCTAssertEqual(duration.seconds, 600, accuracy: 1)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: loader.asset))
        defer { player.pause(); player.replaceCurrentItem(with: nil); loader.cancel() }
        try await waitUntil { player.currentItem?.status == .readyToPlay }
        let sought = await player.seek(to: CMTime(seconds: 550, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought)
        XCTAssertEqual(player.currentTime().seconds, 550, accuracy: 1)
        let ranges = await spy.ranges
        XCTAssertTrue(ranges.contains { $0.0 > Int64(bytes.count / 2) }, "MP4 tail was never read")
        XCTAssertTrue(ranges.allSatisfy { $0.1 <= 1_024 * 1_024 })
        XCTAssertNil(source.localURL)
    }
    func testResumeLocalThenStreamAndNextEpisodeVisibilityAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryRoot = root
        let store = try VaultFolderStore(rootURL: root), history = VaultVideoHistory(store: store)
        temporaryStore = store
        let url = try fixture(), bytes = try Data(contentsOf: url)
        let firstName = "TV/Show S01E01.mp4", secondName = "TV/Show S01E02.mp4"
        try history.save(VaultVideoProgress(seconds: 450, duration: 600), for: firstName)
        let local = VaultMediaSource(identity: firstName, name: firstName, size: Int64(bytes.count), localURL: url) { _, _ in throw CocoaError(.fileReadUnknown) }
        let controller = VaultVideoPlayerViewController(source: local, history: history,
            sourceProvider: { name in VaultMediaSource(identity: name, name: name, size: Int64(bytes.count)) { offset, length in
                bytes.subdata(in: Int(offset)..<(Int(offset) + length))
            } }, siblingsProvider: { [firstName, secondName] })
        try host(controller)
        let av = try XCTUnwrap(controller.children.first as? AVPlayerViewController), player = try XCTUnwrap(av.player)
        try await waitUntil { player.currentTime().seconds >= 450 && player.rate > 0 }
        player.pause()
        let button = try XCTUnwrap(nextButton(controller.view))
        try await waitUntil { !button.isHidden }
        XCTAssertEqual(player.currentTime().seconds, 450, accuracy: 3)
        player.play()
        try await waitUntil { button.isHidden }
        _ = await player.seek(to: CMTime(seconds: 550, preferredTimescale: 600))
        try await waitUntil { !button.isHidden }
        try await waitUntil { button.configuration?.image?.isSymbolImage == false }
        let rendered = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "Vault Up Next in final minute"; attachment.lifetime = .keepAlways; add(attachment)
        // The next episode is another remote source; the player stays open.
        button.sendActions(for: .touchUpInside)
        try await waitUntil { player.rate > 0 && player.currentTime().seconds < 10 }
        XCTAssertGreaterThan(try XCTUnwrap(history.progress(for: firstName)).seconds, 540)
        player.pause()
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        XCTAssertNotNil(try history.progress(for: secondName))
        let remote = VaultMediaSource(identity: firstName, name: firstName, size: Int64(bytes.count)) { offset, length in
            bytes.subdata(in: Int(offset)..<(Int(offset) + length))
        }
        let reopened = VaultVideoPlayerViewController(source: remote, history: history,
            sourceProvider: { _ in remote }, siblingsProvider: { [] })
        try host(reopened)
        let remotePlayer = try XCTUnwrap((reopened.children.first as? AVPlayerViewController)?.player)
        try await waitUntil { remotePlayer.currentTime().seconds > 540 && remotePlayer.rate > 0 }
        reopened.beginAppearanceTransition(false, animated: false)
        reopened.endAppearanceTransition()
        XCTAssertEqual(try store.cacheTotals().bytes, 0, "Streaming installed a downloaded file")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: store.cacheDirectory.path)).isEmpty)
    }
}
