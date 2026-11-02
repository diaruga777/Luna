import LunaCompanionSharing
import UIKit
import UniformTypeIdentifiers
import LunaCompanionShareCore
import XCTest
@testable import LunaMusicUI
import AVFoundation
@testable import LunaMusicCore
import LunaPodcastCore
import LunaMusicFiles
@testable import LunaMusicSharing

@MainActor final class PodcastAutomationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PodcastAutomationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func audio() throws -> URL {
        let source = directory.appendingPathComponent("Source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        buffer.frameLength = 22_050
        for index in 0..<22_050 { buffer.floatChannelData![0][index] = 0 }
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
        return source
    }
    func testImportCopiesFileQueuesAndDeduplicatesByKey() async throws {
        let source = try audio()
        let library = PodcastLibraryController(url: directory.appendingPathComponent("Library/library.json"))
        let list = try PodcastAutomation.createAudioList(name: "Articles", library: library)
        let episode = try await PodcastAutomation.importAudio(at: source, title: "An Article", listID: list.id,
            enqueue: true, importKey: "reader-save-1", library: library)
        XCTAssertNotEqual(source, episode.mediaURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: episode.mediaURL.path))
        XCTAssertEqual(library.state.queue, [episode.id])
        try FileManager.default.removeItem(at: source)
        // A retry can return the existing import even if the input has expired.
        let repeated = try await PodcastAutomation.importAudio(at: source, title: "Another Title", listID: list.id,
            enqueue: true, importKey: "reader-save-1", library: library)
        XCTAssertEqual(repeated.id, episode.id)
        XCTAssertEqual(library.state.episodes.count, 1)
        XCTAssertEqual(library.state.queue, [episode.id])
        XCTAssertEqual(repeated.title, "An Article")
    }
    func testImportWithoutQueueStillReturnsPlayableEpisode() async throws {
        let library = PodcastLibraryController(url: directory.appendingPathComponent("Library/library.json"))
        let episode = try await PodcastAutomation.importAudio(at: audio(), title: "", listID: nil, enqueue: false, library: library)
        XCTAssertEqual(episode.title, "Source")
        XCTAssertTrue(library.state.queue.isEmpty)
        XCTAssertNotNil(library.state.shows[episode.showID])
    }
    func testExternalAudioIsExcludedFromCloudLibrary() async throws {
        let library = PodcastLibraryController(url: directory.appendingPathComponent("Library/library.json"))
        let list = try PodcastAutomation.createAudioList(name: "Articles", library: library)
        let episode = try await PodcastAutomation.importAudio(at: audio(), title: "Article", listID: list.id, enqueue: true, library: library)
        let cloud = ReaderPodcastSource.cloudState(library.state)
        XCTAssertNil(cloud.shows[list.id]); XCTAssertNil(cloud.episodes[episode.id]); XCTAssertTrue(cloud.queue.isEmpty)
    }
    func testRejectsFeedAsLocalImportDestination() async throws {
        let library = PodcastLibraryController(url: directory.appendingPathComponent("Library/library.json"))
        let show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "RSS")
        try library.edit { $0.shows[show.id] = show }
        do {
            _ = try await PodcastAutomation.importAudio(at: audio(), title: "Article", listID: show.id, enqueue: true, library: library)
            XCTFail("Expected a local audio list validation error")
        } catch { XCTAssertTrue(library.state.episodes.isEmpty) }
    }
    func testInitialProgressAndPositionTicksAreNotAutomationChanges() throws {
        var before = PodcastLibraryState()
        let episode = PodcastEpisode(showID: "show", guid: "episode", title: "Episode", publishedAt: Date(), mediaURL: URL(string: "https://example.com/audio.mp3")!)
        before.episodes[episode.id] = episode
        var after = before
        after.progress[episode.id] = PodcastEpisodeState()
        XCTAssertTrue(PodcastAutomation.changes(from: before, to: after).isEmpty)
        after.progress[episode.id]?.position = 12
        XCTAssertTrue(PodcastAutomation.changes(from: before, to: after).isEmpty)
        after.progress[episode.id]?.listened = true
        let changes = PodcastAutomation.changes(from: before, to: after)
        XCTAssertEqual(changes.map(\.itemID), [episode.id])
        XCTAssertEqual(changes.map(\.operation), ["updated"])
    }

}

@MainActor final class YouTubePodcastTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("YouTubePodcastTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func episode() -> PodcastEpisode {
        var episode = PodcastEpisode(showID: YouTubePodcastController.showID, guid: "cwAkcsg7NCg", title: "YouTube Audio", publishedAt: Date(), mediaURL: URL(string: "https://www.youtube.com/watch?v=cwAkcsg7NCg")!)
        episode.youtubeVideoID = "cwAkcsg7NCg"; episode.mediaType = "audio/mp4"
        return episode
    }
    private func library() -> PodcastLibraryController { PodcastLibraryController(url: root.appendingPathComponent("library.json")) }
    private func attach(_ transport: YouTubeTestTransport, to controller: YouTubePodcastController) {
        controller.configure { try await transport.respond($0) }
    }
    func testDirectDownloadUsesHeadersAndDoesNotRequestMacDownload() async throws {
        let file = root.appendingPathComponent("direct.m4a"); try Data([1, 2, 3]).write(to: file)
        let library = library()
        try library.edit { $0.settings.cellularDownloads = false }
        let controller = YouTubePodcastController(library: library, directDownload: { request, _, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Test Agent")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.youtube.com/")
            XCTAssertFalse(request.allowsCellularAccess)
            return file
        }, validate: { _ in 10 })
        let transport = YouTubeTestTransport(); attach(transport, to: controller)
        let audio = try await controller.download(episode(), maximumBytes: 1_000_000, progress: { _ in })
        XCTAssertEqual(audio.url, file); XCTAssertEqual(audio.duration, 10)
        let actions = await transport.actions
        XCTAssertFalse(actions.contains(.download)); XCTAssertFalse(actions.contains(.read)); XCTAssertEqual(actions.last, .release)
    }
    func testMediaRejectionDownloadsOnMacThenTransfersEveryByte() async throws {
        let controller = YouTubePodcastController(library: library(), directDownload: { _, _, _ in throw YouTubeMediaRejection() }, validate: { _ in 10 })
        let bytes = Data(repeating: 42, count: MusicFileProtocol.chunkSize * 2 + 19)
        let transport = YouTubeTestTransport(bytes: bytes); attach(transport, to: controller)
        let result = try await controller.download(episode(), maximumBytes: Int64(bytes.count), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(try Data(contentsOf: result.url), bytes)
        let actions = await transport.actions
        XCTAssertEqual(actions.filter { $0 == .download }.count, 1)
        XCTAssertEqual(actions.filter { $0 == .read }.count, 3)
        XCTAssertEqual(actions.last, .release)
    }
    func testConnectivityFailuresNeverAskMacToDownload() async throws {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed] {
            let controller = YouTubePodcastController(library: library(), directDownload: { _, _, _ in throw URLError(code) }, validate: { _ in XCTFail("Validation after network failure"); return 10 })
            let transport = YouTubeTestTransport(); attach(transport, to: controller)
            do { _ = try await controller.download(episode(), maximumBytes: 100, progress: { _ in }); XCTFail("Expected connectivity error") }
            catch { XCTAssertEqual((error as? URLError)?.code, code) }
            let actions = await transport.actions
            XCTAssertFalse(actions.contains(.download), "\(code)"); XCTAssertEqual(actions.last, .release)
        }
    }
    func testDiskFailureNeverAsksMacToDownload() async throws {
        let controller = YouTubePodcastController(library: library(), directDownload: { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) }, validate: { _ in 10 })
        let transport = YouTubeTestTransport(); attach(transport, to: controller)
        do { _ = try await controller.download(episode(), maximumBytes: 100, progress: { _ in }); XCTFail("Expected disk error") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        let actions = await transport.actions
        XCTAssertFalse(actions.contains(.download))
    }
    func testUnplayableDirectFileIsRemovedBeforeMacFallback() async throws {
        let direct = root.appendingPathComponent("unplayable.m4a"); try Data([1]).write(to: direct)
        let controller = YouTubePodcastController(library: library(), directDownload: { _, _, _ in direct }, validate: { url in
            if url == direct { throw YouTubeMediaRejection() }; return 10
        })
        let transport = YouTubeTestTransport(); attach(transport, to: controller)
        let audio = try await controller.download(episode(), maximumBytes: 100, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: audio.url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: direct.path))
        let actions = await transport.actions; XCTAssertTrue(actions.contains(.download))
    }
    func testCapabilityDefaultsHiddenAndDisconnectPreservesIt() async {
        let controller = YouTubePodcastController(library: library())
        XCTAssertFalse(controller.available)
        let transport = YouTubeTestTransport(); attach(transport, to: controller)
        await controller.refreshAvailability(); XCTAssertTrue(controller.available)
        controller.disconnected(); XCTAssertTrue(controller.available)
        await transport.setAvailable(false)
        await controller.refreshAvailability(); XCTAssertFalse(controller.available)
    }
    func testCapabilityCacheSurvivesRelaunchFailureAndPeerChanges() async throws {
        let suite = "YouTubeCapabilityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var peer = "mac-a"
        let first = YouTubePodcastController(library: library(), defaults: defaults)
        first.configure(peer: { peer }) { _ in
            var response = MusicFileResponse(); response.youtube = .init(available: true)
            return try JSONEncoder().encode(response)
        }
        await first.refreshAvailability(); XCTAssertTrue(first.available)
        let restored = YouTubePodcastController(library: library(), defaults: defaults)
        restored.configure(peer: { peer }) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(restored.available)
        await restored.refreshAvailability(); XCTAssertTrue(restored.available)
        restored.disconnected(); XCTAssertTrue(restored.available)
        peer = "mac-b"; restored.restoreAvailability(); XCTAssertFalse(restored.available)
        peer = ""; restored.restoreAvailability(); XCTAssertFalse(restored.available)
        peer = "mac-a"
        restored.configure(peer: { peer }) { _ in
            var response = MusicFileResponse(); response.youtube = .init(available: false)
            return try JSONEncoder().encode(response)
        }
        XCTAssertTrue(restored.available)
        await restored.refreshAvailability(); XCTAssertFalse(restored.available)
        first.configure(peer: { peer }) { _ in throw URLError(.timedOut) }
        XCTAssertFalse(first.available)
    }
    func testLateCapabilityReplyCannotDisplayAnotherMacsAvailability() async throws {
        let suite = "YouTubeCapabilityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var peer = "mac-a"
        let controller = YouTubePodcastController(library: library(), defaults: defaults)
        controller.configure(peer: { peer }) { _ in
            var response = MusicFileResponse(); response.youtube = .init(available: true)
            return try JSONEncoder().encode(response)
        }
        await controller.refreshAvailability(); XCTAssertTrue(controller.available)
        controller.configure(peer: { peer }) { _ in
            peer = "mac-b"
            var response = MusicFileResponse(); response.youtube = .init(available: true)
            return try JSONEncoder().encode(response)
        }
        XCTAssertTrue(controller.available)
        await controller.refreshAvailability(); XCTAssertFalse(controller.available)
        // The late reply must not replace the cache of the original Mac.
        peer = "mac-a"; controller.restoreAvailability(); XCTAssertTrue(controller.available)
    }
    func testDownloadedYouTubeAudioUsesPodcastManifestCapAndCleanup() async throws {
        let library = library(), episode = episode()
        try library.edit { $0.episodes[episode.id] = episode; $0.queue = [episode.id]; $0.settings.downloadByteLimit = 100 }
        let downloads = PodcastDownloads(directory: root.appendingPathComponent("Downloads"), library: library, sessionConfiguration: .ephemeral)
        defer { downloads.stop() }
        let file = root.appendingPathComponent("audio.m4a"); try Data(repeating: 1, count: 16).write(to: file)
        downloads.youtubeDownload = { _, budget, _ in XCTAssertEqual(budget, 100); return .init(url: file, duration: 10) }
        await downloads.download(episode)
        for _ in 0..<200 {
            if downloads.localURL(episode.id) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let installed = try XCTUnwrap(downloads.localURL(episode.id))
        XCTAssertEqual(downloads.totalBytes, 16); XCTAssertEqual(downloads.cachedDuration(episode.id), 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let restored = PodcastDownloads(directory: root.appendingPathComponent("Downloads"), library: library, sessionConfiguration: .ephemeral)
        defer { restored.stop() }
        XCTAssertEqual(restored.localURL(episode.id), installed)
        downloads.remove(episode.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(library.state.progress[episode.id]?.suppressAutomaticDownload, true)
    }
    func testSessionDelegateRejectionFallsBackButConnectivityDoesNot() async throws {
        for rejectsMedia in [true, false] {
            let library = library(), episode = episode()
            try library.edit { $0.episodes[episode.id] = episode; $0.queue = [episode.id] }
            let controller = YouTubePodcastController(library: library, validate: { _ in 10 })
            let transport = YouTubeTestTransport(); attach(transport, to: controller)
            YouTubeDownloadProtocol.rejectsMedia = rejectsMedia
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [YouTubeDownloadProtocol.self]
            let downloads = PodcastDownloads(directory: root.appendingPathComponent(UUID().uuidString), library: library, sessionConfiguration: config)
            downloads.youtubeController = controller
            await downloads.download(episode)
            for _ in 0..<500 {
                if ["failed", "downloaded"].contains(downloads.downloads[episode.id]?.status ?? "") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let actions = await transport.actions
            if rejectsMedia {
                XCTAssertEqual(downloads.downloads[episode.id]?.status, "downloaded")
                XCTAssertTrue(actions.contains(.download))
            } else {
                XCTAssertEqual(downloads.downloads[episode.id]?.status, "failed")
                XCTAssertFalse(actions.contains(.download))
            }
            downloads.remove(episode.id); downloads.stop()
        }
    }
    func testRemovingAnInFlightYouTubeDownloadCannotInstallItsLateResult() async throws {
        let library = library(), episode = episode()
        try library.edit { $0.episodes[episode.id] = episode; $0.queue = [episode.id] }
        let downloads = PodcastDownloads(directory: root.appendingPathComponent("Downloads"), library: library, sessionConfiguration: .ephemeral)
        defer { downloads.stop() }
        let file = root.appendingPathComponent("late.m4a"); try Data([1, 2, 3]).write(to: file)
        downloads.youtubeDownload = { _, _, _ in
            try? await Task.sleep(for: .milliseconds(150))
            return .init(url: file, duration: 10)
        }
        await downloads.download(episode)
        await Task.yield()
        downloads.remove(episode.id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(downloads.localURL(episode.id)); XCTAssertNil(downloads.downloads[episode.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testSharingURLsQueueOneStableEpisodeWithoutPersistingSignedMetadata() async throws {
        let library = library(), transport = YouTubeTestTransport()
        let core = YouTubePodcastController(library: library, startDownload: { _ in })
        attach(transport, to: core); await core.refreshAvailability()
        let first = try await core.enqueue("https://youtu.be/cwAkcsg7NCg?si=shared")
        let second = try await core.enqueue("https://www.youtube.com/watch?v=cwAkcsg7NCg&t=12")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(library.state.queue, [first.id]); XCTAssertEqual(library.state.episodes.count, 1)
        let persisted = String(data: try Data(contentsOf: library.requireStore().url), encoding: .utf8)!
        XCTAssertFalse(persisted.contains("expire=")); XCTAssertFalse(persisted.contains("Test Agent"))
        XCTAssertEqual(library.state.episodes[first.id]?.youtubeVideoID, "cwAkcsg7NCg")
        let actions = await transport.actions
        XCTAssertEqual(actions.filter { $0 == .resolve }.count, 1)
        XCTAssertFalse(actions.contains(.download))
    }
    func testPasteRowTracksCapabilityAndSitsBelowHome() async throws {
        let core = YouTubePodcastController(library: library()), transport = YouTubeTestTransport()
        attach(transport, to: core)
        let browser = PodcastBrowserViewController(); browser.youtube = core
        browser.loadViewIfNeeded(); browser.mode = 4; browser.title = "Podcasts"
        func actions() -> [String] {
            browser.sections.flatMap(\.rows).compactMap { row in
                if case .action(let title, _, _) = row { return title }; return nil
            }
        }
        XCTAssertFalse(actions().contains("Add YouTube Audio"))
        await core.refreshAvailability()
        try await Task.sleep(for: .milliseconds(20))
        let titles = actions()
        let home = try XCTUnwrap(titles.firstIndex(of: "Home"))
        XCTAssertEqual(titles[home + 1], "Add YouTube Audio")
        let navigation = UINavigationController(rootViewController: browser)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        navigation.view.frame = window.bounds; navigation.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        browser.table.reloadData(); browser.table.layoutIfNeeded()
        XCTAssertTrue(browser.table.visibleCells.contains { ($0.contentConfiguration as? UIListContentConfiguration)?.text == "Add YouTube Audio" })
        let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "YouTube audio enabled in Podcasts"; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true
        await transport.setAvailable(false); await core.refreshAvailability()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(actions().contains("Add YouTube Audio"))
    }
    func testYouTubeEpisodeKeepsStableSourceAndStaysOutOfCloud() throws {
        let library = library(), episode = episode()
        var show = PodcastShow(feedURL: URL(string: "lunamusic://youtube")!, title: "YouTube", id: episode.showID)
        show.settings.automaticDownloadLimit = 0
        try library.edit { $0.episodes[episode.id] = episode; $0.shows[show.id] = show; $0.queue = [episode.id] }
        let encoded = try JSONEncoder().encode(library.state)
        let restored = try JSONDecoder().decode(PodcastLibraryState.self, from: encoded)
        XCTAssertEqual(restored.episodes[episode.id]?.youtubeVideoID, "cwAkcsg7NCg")
        XCTAssertEqual(restored.episodes[episode.id]?.mediaURL, episode.mediaURL)
        XCTAssertTrue(ReaderPodcastSource.cloudState(restored).episodes.isEmpty)
    }
}

private actor YouTubeTestTransport {
    private(set) var actions: [YouTubeAudioRequest.Action] = []
    private var downloading = false
    private var available = true
    private let bytes: Data
    init(bytes: Data = Data(repeating: 1, count: 16)) { self.bytes = bytes }
    func setAvailable(_ value: Bool) { available = value }
    func respond(_ data: Data) throws -> Data {
        let envelope = try JSONDecoder().decode(MusicFileRequest.self, from: data)
        let request = try XCTUnwrap(envelope.youtube)
        actions.append(request.action)
        var response = YouTubeAudioResponse()
        switch request.action {
        case .availability: response.available = available
        case .resolve: response.state = .resolving
        case .status:
            response.state = downloading ? .ready : .resolved
            response.size = Int64(bytes.count)
            response.metadata = .init(videoID: "cwAkcsg7NCg", title: "Title", author: "Author", duration: 10,
                downloadURL: URL(string: "https://audio.googlevideo.com/audio?expire=123")!,
                headers: ["User-Agent": "Test Agent", "Referer": "https://www.youtube.com/"])
        case .download: downloading = true; response.state = .downloading
        case .read:
            response.state = .ready; response.size = Int64(bytes.count)
            response.data = bytes.subdata(in: Int(request.offset)..<(Int(request.offset) + request.length))
        case .release: break
        }
        var result = MusicFileResponse(); result.youtube = response
        return try JSONEncoder().encode(result)
    }
}

private final class YouTubeDownloadProtocol: URLProtocol, @unchecked Sendable {
    static var rejectsMedia = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.rejectsMedia {
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    }
    override func stopLoading() {}
}

@MainActor final class CompanionShareImportTests: XCTestCase {
    func testExtensionlessSharedImageKeepsItsBytesAndGetsAUsableFileType() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let source = root.appendingPathComponent("image")
        try bytes.write(to: source)
        let provider = NSItemProvider(); provider.suggestedName = "image"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.image.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil); return nil
        }
        let staged = try await SharedInput.file(provider, conformingTo: .image)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(staged.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }
    func testUIKitImageObjectIsStoredAsAnImageInsteadOfAKeyedArchive() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let url = try await SharedInput.file(NSItemProvider(object: image), conformingTo: .image)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(["png", "jpg", "jpeg", "heic"].contains(url.pathExtension))
        XCTAssertNotNil(UIImage(contentsOfFile: url.path))
    }
    func testArchivedUIKitImageFromAnotherProcessBecomesAUsableImageFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let source = root.appendingPathComponent("image")
        try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true).write(to: source)
        let provider = NSItemProvider(); provider.suggestedName = "image"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.image.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil); return nil
        }
        let staged = try await SharedInput.file(provider, conformingTo: .image)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(staged.pathExtension, "png")
        XCTAssertNotNil(UIImage(contentsOfFile: staged.path))
    }
    func testInboxCopiesBeforePublishingAndIgnoresIncompleteCaptures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CompanionShareInbox(root: root.appendingPathComponent("Inbox"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Audio.wav")
        try Data([1, 2, 3]).write(to: source)
        let capture = CompanionShareCapture(kind: .podcast, filenames: ["0-Audio.wav"], playNext: true)
        try inbox.save(capture, files: [source]); try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try inbox.pending().map(\.id), [capture.id])
        XCTAssertEqual(try Data(contentsOf: inbox.directory(for: capture).appendingPathComponent("0-Audio.wav")), Data([1, 2, 3]))
        let invalid = CompanionShareCapture(kind: .song, filenames: ["../escape.wav"])
        XCTAssertThrowsError(try inbox.save(invalid, files: [source]))
        XCTAssertEqual(try inbox.pending().count, 1)
        try inbox.remove(capture); XCTAssertTrue(try inbox.pending().isEmpty)
    }
    func testPodcastPlayNextPreservesSelectionOrderAndReplayDoesNotDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CompanionShareInbox(root: root.appendingPathComponent("Inbox"))
        let source = try makeAudio(root)
        let capture = CompanionShareCapture(kind: .podcast, filenames: ["0-First.wav", "1-Second.wav"], playNext: true)
        try inbox.save(capture, files: [source, source])
        let podcasts = PodcastLibraryController(url: root.appendingPathComponent("Podcasts/library.json"))
        let music = VaultMusicController(directory: root.appendingPathComponent("Music"))
        try await MusicShareImport.importCapture(capture, inbox: inbox, podcasts: podcasts, music: music)
        try await MusicShareImport.importCapture(capture, inbox: inbox, podcasts: podcasts, music: music)
        XCTAssertEqual(podcasts.state.episodes.count, 2)
        XCTAssertEqual(podcasts.state.queue.compactMap { podcasts.state.episodes[$0]?.title }, ["First", "Second"])
    }
    func testImportedSongSurvivesRestartAndCanBelongToSeveralPlaylists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeAudio(root)
        let musicRoot = root.appendingPathComponent("Music")
        let music = VaultMusicController(directory: musicRoot)
        let first = try music.createPlaylist(name: "First", songs: [])
        let second = try music.createPlaylist(name: "Second", songs: [])
        for _ in 0..<2 {
            try await music.importSong(at: source, key: "test-song", title: "Audio", playlists: [first.persistentID, second.persistentID])
        }
        try FileManager.default.removeItem(at: source)
        let restored = VaultMusicController(directory: musicRoot)
        XCTAssertEqual(restored.songs.count, 1)
        let song = try XCTUnwrap(restored.songs.first)
        XCTAssertNotNil(restored.localURL(song))
        XCTAssertTrue(restored.playlists.allSatisfy { $0.items.map(\.persistentID) == [song.persistentID] })
        try await restored.removeCachedSong(song)
        XCTAssertNotNil(restored.localURL(song))
    }
    private func makeAudio(_ root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Original.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        buffer.frameLength = 22_050
        buffer.floatChannelData![0].initialize(repeating: 0, count: 22_050)
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
        return url
    }
}

@MainActor final class YouTubeShareTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("YouTubeShareTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testShareResolvesCanonicalVideoWithLiveCapabilityCheckAndReleasesTicket() async throws {
        let transport = YouTubeTestTransport()
        let result = try await MusicYouTubeShare.resolve("https://youtu.be/cwAkcsg7NCg?si=tracking") { try await transport.respond($0) }
        XCTAssertEqual(result.metadata.videoID, "cwAkcsg7NCg")
        let actions = await transport.actions
        XCTAssertEqual(actions, [.availability, .resolve, .status, .release])
    }
    func testUnavailableAndIncompatibleLinksUseIdenticalGenericError() async throws {
        let transport = YouTubeTestTransport(); await transport.setAvailable(false)
        for input in ["https://example.com/article", "https://youtu.be/cwAkcsg7NCg"] {
            do {
                _ = try await MusicYouTubeShare.resolve(input) { try await transport.respond($0) }
                XCTFail("Expected rejection")
            } catch { XCTAssertEqual(error.localizedDescription, MusicYouTubeShare.unsupportedMessage) }
        }
        let actions = await transport.actions
        XCTAssertFalse(actions.contains(.resolve))
    }
    func testTransportErrorsDoNotExposeIntegrationDetails() async {
        do {
            _ = try await MusicYouTubeShare.resolve("https://youtu.be/cwAkcsg7NCg") { _ in throw PodcastError("yt-dlp is not installed") }
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error.localizedDescription, MusicYouTubeShare.unsupportedMessage) }
    }
    func testUnsafeResolvedHeadersAreRejected() async throws {
        let transport = YouTubeTestTransport()
        do {
            _ = try await MusicYouTubeShare.resolve("https://youtu.be/cwAkcsg7NCg") { data in
                var response = try JSONDecoder().decode(MusicFileResponse.self, from: await transport.respond(data))
                response.youtube?.metadata?.headers["Injected"] = "value\r\nOther: header"
                return try JSONEncoder().encode(response)
            }
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error.localizedDescription, MusicYouTubeShare.unsupportedMessage) }
    }
    func testOldCapturesAndChoicesStillDecode() throws {
        let original = CompanionShareCapture(kind: .podcast, filenames: ["0-Test.wav"])
        let decoded = try JSONDecoder().decode(CompanionShareCapture.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.youtube)
        let choices = try JSONDecoder().decode(CompanionShareChoices.self, from: Data("{\"playlists\":[],\"audioLists\":[]}".utf8))
        XCTAssertNil(choices.cellularDownloads); XCTAssertNil(choices.downloadBytesAvailable)
    }
    func testCompletedShareInstallsOwnedDownloadAndReplayDoesNotDuplicateQueue() async throws {
        let (capture, inbox, library, downloads) = try fixture()
        defer { downloads.stop() }
        try await downloads.importSharedYouTube(capture, inbox: inbox)
        let id = try XCTUnwrap(library.state.queue.first)
        XCTAssertEqual(library.state.episodes[id]?.youtubeVideoID, "cwAkcsg7NCg")
        XCTAssertEqual(library.state.episodes[id]?.mediaURL.absoluteString, "https://www.youtube.com/watch?v=cwAkcsg7NCg")
        XCTAssertEqual(downloads.downloads[id]?.status, "downloaded")
        XCTAssertNotNil(downloads.localURL(id))
        try await downloads.importSharedYouTube(capture, inbox: inbox)
        XCTAssertEqual(library.state.queue, [id]); XCTAssertEqual(library.state.episodes.count, 1)
        try inbox.remove(capture)
        XCTAssertNotNil(downloads.localURL(id))
        let manifest = try String(contentsOf: root.appendingPathComponent("Downloads/downloads.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("googlevideo")); XCTAssertFalse(manifest.contains("Authorization"))
    }
    func testPlayNextUsesExistingPodcastQueue() async throws {
        let (capture, inbox, library, downloads) = try fixture(next: true)
        defer { downloads.stop() }
        let existing = try YouTubePodcastController(library: library).enqueueResolved(video: "abcdefghijk", title: "Existing", author: "", duration: 1, next: false)
        try await downloads.importSharedYouTube(capture, inbox: inbox)
        XCTAssertEqual(library.state.queue.count, 2)
        XCTAssertEqual(library.state.queue.last, existing.id)
        XCTAssertEqual(library.state.episodes[library.state.queue[0]]?.youtubeVideoID, "cwAkcsg7NCg")
    }
    func testPendingShareDoesNotCreateAnUnownedDownload() async throws {
        let (capture, inbox, library, downloads) = try fixture()
        defer { downloads.stop() }
        try FileManager.default.removeItem(at: inbox.directory(for: capture).appendingPathComponent("transfer.json"))
        try await downloads.importSharedYouTube(capture, inbox: inbox)
        XCTAssertTrue(library.state.queue.isEmpty); XCTAssertTrue(downloads.downloads.isEmpty)
        XCTAssertEqual(try inbox.pending().count, 1)
    }
    func testChangedByteLimitRetainsRetryableQueueItemWithoutInstallingAudio() async throws {
        let (capture, inbox, library, downloads) = try fixture()
        defer { downloads.stop() }
        try library.edit { $0.settings.downloadByteLimit = 10 }
        try await downloads.importSharedYouTube(capture, inbox: inbox)
        let id = try XCTUnwrap(library.state.queue.first)
        XCTAssertNil(downloads.localURL(id)); XCTAssertEqual(downloads.downloads[id]?.status, "failed")
    }
    func testNetworkFailureDoesNotRequestMacFallback() async throws {
        let (capture, inbox, library, downloads) = try fixture()
        defer { downloads.stop() }
        downloads.youtubeDownload = { _, _, _ in XCTFail("Network failure must not retry through the Mac"); throw CancellationError() }
        try outcome(["error": "The Internet connection appears to be offline.", "mediaRejected": false], capture: capture, inbox: inbox)
        try await downloads.importSharedYouTube(capture, inbox: inbox)
        let id = try XCTUnwrap(library.state.queue.first)
        XCTAssertEqual(downloads.downloads[id]?.status, "failed")
        XCTAssertEqual(downloads.downloads[id]?.error, "The Internet connection appears to be offline.")
    }
    func testMediaRejectionStartsFallbackAndInstallsAudio() async throws {
        let (capture, inbox, library, downloads) = try fixture()
        defer { downloads.stop() }
        let file = inbox.directory(for: capture).appendingPathComponent("audio.m4a")
        var calls = 0
        downloads.youtubeDownload = { _, _, _ in calls += 1; return .init(url: file, duration: 1) }
        try outcome(["error": "Rejected media", "mediaRejected": true], capture: capture, inbox: inbox)
        try await downloads.importSharedYouTube(capture, inbox: inbox)
        let id = try XCTUnwrap(library.state.queue.first)
        for _ in 0..<100 where downloads.localURL(id) == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 1); XCTAssertNotNil(downloads.localURL(id))
    }
    func testExtensionSessionStagesDownloadBeforePublishingCompletion() async throws {
        let (capture, inbox, _, downloads) = try fixture()
        defer { downloads.stop() }
        let directory = inbox.directory(for: capture)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transfer.json"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("audio.m4a"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [YouTubeShareProtocol.self]
        let transfer = MusicYouTubeShare(capture: capture, inbox: inbox, identifier: UUID().uuidString, configuration: config)
        transfer.begin(URLRequest(url: URL(string: "https://audio.example.com/file")!))
        for _ in 0..<100 {
            if case .downloaded(let file) = try MusicYouTubeShare.result(for: capture, inbox: inbox) {
                XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected a durable completed transfer")
    }
    func testShareSheetOffersPodcastActionsForSharedTextLink() async throws {
        let controller = MusicShareTestController()
        controller.context.items = [shareItem(NSItemProvider(object: "A video title\nhttps://youtu.be/cwAkcsg7NCg?si=tracking" as NSString))]
        let transport = YouTubeTestTransport()
        controller.resolveYouTube = { try await MusicYouTubeShare.resolve($0) { try await transport.respond($0) } }
        controller.loadViewIfNeeded()
        for _ in 0..<100 where controller.status.text != "Title" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.status.text, "Title")
        XCTAssertTrue(controller.stack.arrangedSubviews.compactMap { $0 as? UISegmentedControl }.allSatisfy(\.isHidden))
        let buttons = controller.stack.arrangedSubviews.compactMap { $0 as? UIButton }
        for title in ["Add to Queue", "Play Next"] {
            let button = try XCTUnwrap(buttons.first { $0.configuration?.title == title })
            XCTAssertTrue(button.isEnabled); XCTAssertFalse(button.isHidden)
        }
    }
    func testShareSheetShowsSameGenericErrorForUnsupportedAndUnavailableLinks() async throws {
        for input in ["https://example.com/article", "https://youtu.be/cwAkcsg7NCg"] {
            let controller = MusicShareTestController()
            controller.context.items = [shareItem(NSItemProvider(object: URL(string: input)! as NSURL))]
            let transport = YouTubeTestTransport(); await transport.setAvailable(false)
            controller.resolveYouTube = { try await MusicYouTubeShare.resolve($0) { try await transport.respond($0) } }
            controller.loadViewIfNeeded()
            for _ in 0..<100 where controller.status.text != MusicYouTubeShare.unsupportedMessage { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(controller.status.text, MusicYouTubeShare.unsupportedMessage)
            XCTAssertTrue(controller.stack.arrangedSubviews.compactMap { $0 as? UIButton }.filter { ["Add to Queue", "Play Next"].contains($0.configuration?.title ?? "") }.allSatisfy { !$0.isEnabled })
        }
    }
    private func shareItem(_ provider: NSItemProvider) -> NSExtensionItem {
        let item = NSExtensionItem(); item.attachments = [provider]; return item
    }
    private func outcome(_ json: [String: Any], capture: CompanionShareCapture, inbox: CompanionShareInbox) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: inbox.directory(for: capture).appendingPathComponent("transfer.json"), options: .atomic)
    }
    private func fixture(next: Bool = false) throws -> (CompanionShareCapture, CompanionShareInbox, PodcastLibraryController, PodcastDownloads) {
        let inbox = CompanionShareInbox(root: root.appendingPathComponent("Inbox"))
        let capture = CompanionShareCapture(kind: .podcast, text: "https://www.youtube.com/watch?v=cwAkcsg7NCg", title: "Shared Video", playNext: next,
            youtube: .init(videoID: "cwAkcsg7NCg", author: "Creator", duration: 1, maximumBytes: 1_000_000))
        try inbox.save(capture)
        let url = inbox.directory(for: capture).appendingPathComponent("audio.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        buffer.frameLength = 22_050
        for index in 0..<22_050 { buffer.floatChannelData![0][index] = 0 }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1])
        try file.write(from: buffer)
        try outcome(["mediaRejected": false], capture: capture, inbox: inbox)
        let library = PodcastLibraryController(url: root.appendingPathComponent("Library/library.json"))
        let downloads = PodcastDownloads(directory: root.appendingPathComponent("Downloads"), library: library, sessionConfiguration: .ephemeral)
        return (capture, inbox, library, downloads)
    }
}

private final class MusicShareTestContext: NSExtensionContext {
    var items: [NSExtensionItem] = []
    override var inputItems: [Any] { items }
}
private final class MusicShareTestController: MusicAudioShareViewController {
    let context = MusicShareTestContext()
    override var extensionContext: NSExtensionContext? { context }
}
private final class YouTubeShareProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mp4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
