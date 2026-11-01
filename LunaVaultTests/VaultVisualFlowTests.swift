import XCTest
import UIKit
import LunaVaultUI
import LunaVaultBEP

@MainActor
final class VaultVisualFlowTests: XCTestCase {
    private var window: UIWindow?
    private let files = [
        VaultPresentedFile(id: "Travel/Autumn itinerary.pdf", name: "Autumn itinerary.pdf", path: "Travel/Autumn itinerary.pdf", modifiedAt: Date(), byteCount: 245_760),
        VaultPresentedFile(id: "Home renovation notes.txt", name: "Home renovation notes.txt", path: "Home renovation notes.txt", modifiedAt: Date().addingTimeInterval(-86_400), byteCount: 8_192, isDownloaded: true),
        VaultPresentedFile(id: "Coast.jpg", name: "Coast.jpg", path: "Coast.jpg", modifiedAt: Date().addingTimeInterval(-172_800), byteCount: 2_460_000)
    ]
    override func tearDown() { window?.isHidden = true; window = nil; super.tearDown() }

    private func host(_ controller: UIViewController, size: CGSize = CGSize(width: 402, height: 874)) async throws {
        window?.isHidden = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UINavigationController(rootViewController: controller)
        self.window = window
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("UI did not reach expected state")
        throw TestError.failed
    }
    private func capture(_ name: String) async throws {
        try await Task.sleep(for: .milliseconds(250))
        guard let window else { return }
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testFirstRunOffersConnectionAndHidesUnavailableActions() async throws {
        let root = VaultSyncthingHomeViewController(runtime: VaultPresentationServices())
        try await host(root)
        try await waitUntil { (root.emptyStateConfiguration)?.button.title == "Connect Mac" }
        XCTAssertNil(root.navigationItem.searchController)
        XCTAssertNil(root.navigationItem.leftBarButtonItem)
        XCTAssertEqual(root.tableView.numberOfSections, 1)
        try await capture("01-first-run-light")
        window?.overrideUserInterfaceStyle = .dark
        try await capture("02-first-run-dark")
    }
    func testSearchCancelsStaleResultsAndRefreshPreservesQuery() async throws {
        let probe = SearchProbe()
        let root = VaultSyncthingHomeViewController(runtime: VaultPresentationServices(
            connectionStatus: { .connected }, search: { query, _ in await probe.search(query) },
            children: { [files] _ in files }))
        try await host(root)
        let search = try XCTUnwrap(root.navigationItem.searchController)
        search.searchBar.text = "slow"
        root.updateSearchResults(for: search)
        try await Task.sleep(for: .milliseconds(240))
        search.searchBar.text = "new"
        root.updateSearchResults(for: search)
        try await waitUntil { root.emptyStateConfiguration == nil && root.tableView.numberOfRows(inSection: 0) == 1 }
        try await Task.sleep(for: .milliseconds(400))
        let row = root.tableView(root.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual((row.contentConfiguration as? UIListContentConfiguration)?.text, "new.txt")
        let before = await probe.count
        root.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(search.searchBar.text, "new")
        let after = await probe.count
        XCTAssertEqual(before, after, "Connection updates must not restart search or discard results")
        search.searchBar.text = ""
        root.updateSearchResults(for: search)
        XCTAssertEqual(root.tableView.numberOfRows(inSection: 2), files.count)
    }
    func testBrowseSortsFoldersFirstAndReportsFailure() async throws {
        let folder = VaultPresentedFile(id: "Travel", name: "Travel", path: "Travel", modifiedAt: Date(), isDirectory: true)
        let controller = VaultBrowseViewController(runtime: VaultPresentationServices(children: { [files] _ in files + [folder] }), path: "")
        try await host(controller)
        try await waitUntil { controller.tableView.numberOfRows(inSection: 0) == 4 }
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual((cell.contentConfiguration as? UIListContentConfiguration)?.text, "Travel")
        XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
        try await capture("05-browse")
        let failed = VaultBrowseViewController(runtime: VaultPresentationServices(children: { _ in throw TestError.failed }), path: "Travel")
        try await host(failed)
        try await waitUntil { failed.emptyStateConfiguration != nil }
        let config = try XCTUnwrap(failed.emptyStateConfiguration)
        XCTAssertEqual(config.text, "Couldn’t Open Folder")
        XCTAssertEqual(config.button.title, "Try Again")
        try await capture("06-folder-error")
    }
    func testLibraryVisualsAndSearchEmptyState() async throws {
        let root = VaultSyncthingHomeViewController(runtime: VaultPresentationServices(
            connectionStatus: { .offline }, children: { [files] _ in files }))
        try await host(root)
        try await waitUntil { root.tableView.numberOfSections == 3 }
        try await capture("03-library-light")
        window?.overrideUserInterfaceStyle = .dark
        try await capture("04-library-dark")
        let search = try XCTUnwrap(root.navigationItem.searchController)
        search.searchBar.text = "no matching filename"
        root.updateSearchResults(for: search)
        try await waitUntil { (root.emptyStateConfiguration)?.text == "No Results" }
        try await capture("07-search-no-results")
        search.searchBar.text = ""
        root.updateSearchResults(for: search)
        window?.overrideUserInterfaceStyle = .light
        root.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await Task.sleep(for: .milliseconds(100))
        try await capture("08-library-accessibility-text")
    }
    func testConnectedEmptyLibraryKeepsBrowseAndImport() async throws {
        let root = VaultSyncthingHomeViewController(runtime: VaultPresentationServices(connectionStatus: { .connected }))
        try await host(root)
        try await waitUntil { (root.emptyStateConfiguration)?.text == "Your Vault Folder Is Empty" }
        XCTAssertNotNil(root.navigationItem.leftBarButtonItem)
        XCTAssertEqual(root.navigationItem.leftBarButtonItem?.menu?.children.map(\.title),
                       ["Import File", "Import Folder", "Select Photos", "Select Photo Album"])
        XCTAssertEqual(root.tableView.numberOfRows(inSection: 0), 3)
        try await capture("09-connected-empty")
    }
    func testPendingTransferShowsByteProgressPerFile() async throws {
        let item = VaultPendingUpload(name: "Archive.zip", totalBytes: 4 * 1_024 * 1_024 * 1_024,
                                      sentBytes: 1 * 1_024 * 1_024 * 1_024,
                                      isDeleting: false, isDirectory: false)
        let root = VaultTransfersViewController(runtime: VaultPresentationServices(
            connectionStatus: { .connected }, pendingUploads: { [item] }))
        try await host(root)
        try await waitUntil { root.tableView.visibleCells.contains { $0.accessibilityIdentifier?.hasPrefix("vault.transfer.") == true } }
        XCTAssertEqual(root.tableView.numberOfRows(inSection: 0), 1)
        let cell = root.tableView(root.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertFalse(cell.isAccessibilityElement, "VoiceOver must reach the Cancel button")
        let controls = descendants(of: cell)
        XCTAssertTrue(controls.compactMap { ($0 as? UILabel)?.text }.contains("Archive.zip"))
        XCTAssertTrue(controls.compactMap { ($0 as? UILabel)?.text }.contains { $0.contains("of") })
        let cancel = try XCTUnwrap(controls.compactMap { $0 as? UIButton }.first)
        XCTAssertEqual(cancel.accessibilityLabel, "Cancel transfer of Archive.zip")
        try await capture("10-pending-transfer")
        root.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        root.tableView.layoutIfNeeded()
        root.tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        try await capture("10-pending-transfer-large-text")
    }
    func testReceivingSheetSwitchesToBytesAndReportsAStalledPeer() async throws {
        var now = Date()
        let root = UIViewController()
        try await host(root)
        window?.overrideUserInterfaceStyle = .light
        let progress = VaultTransferProgressViewController(filename: "Archive.zip", clock: { now })
        let navigation = UINavigationController(rootViewController: progress)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        root.present(navigation, animated: false)
        progress.loadViewIfNeeded()
        XCTAssertFalse(progress.spinner.isHidden)
        XCTAssertTrue(progress.progressView.isHidden)
        // Even before the Mac returns metadata, a long transfer shows zero
        // bytes and a bar instead of an indefinite activity indicator.
        now = now.addingTimeInterval(2)
        try await waitUntil { !progress.progressView.isHidden }
        XCTAssertTrue(progress.spinner.isHidden)
        XCTAssertFalse(progress.spinner.isAnimating)
        XCTAssertEqual(progress.progressView.progress, 0)
        XCTAssertEqual(progress.byteLabel.text, "Zero KB transferred")
        progress.update(VaultTransferProgress(completedBytes: 194_000_000, totalBytes: 388_000_000))
        XCTAssertEqual(progress.progressView.progress, 0.5)
        XCTAssertTrue(progress.byteLabel.text?.contains("388") == true)
        XCTAssertEqual(progress.title, "Transferring")
        try await capture("transfer-receiving-halfway")
        now = now.addingTimeInterval(16)
        try await waitUntil { progress.statusLabel.text == "Waiting for your Mac…" }
        XCTAssertEqual(progress.progressView.progress, 0.5)
        window?.overrideUserInterfaceStyle = .dark
        progress.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        navigation.sheetPresentationController?.selectedDetentIdentifier = .large
        try await capture("transfer-waiting-dark-large-text")
        progress.update(VaultTransferProgress(completedBytes: 388_000_000, totalBytes: 388_000_000))
        XCTAssertEqual(progress.progressView.progress, 1)
        XCTAssertEqual(progress.statusLabel.text, "Finishing transfer…")
    }

    func testDownloadsAreAccessibleOfflineAndExplainEmptyState() async throws {
        let downloaded = VaultPresentedFile(id: "notes.txt", name: "notes.txt", path: "notes.txt",
            modifiedAt: Date(), byteCount: 512, isDownloaded: true)
        let controller = VaultBrowseViewController(runtime: VaultPresentationServices(
            connectionStatus: { .offline }, downloadedFiles: { [downloaded] }), path: "", downloadsOnly: true)
        try await host(controller)
        try await waitUntil { controller.tableView.numberOfRows(inSection: 0) == 1 }
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertTrue((cell.contentConfiguration as? UIListContentConfiguration)?.secondaryText?.contains("On This iPhone") == true)
        XCTAssertEqual(cell.accessibilityHint, "Open local file")
        try await capture("13-downloads-offline")
        let empty = VaultBrowseViewController(runtime: VaultPresentationServices(), path: "", downloadsOnly: true)
        try await host(empty)
        try await waitUntil { empty.emptyStateConfiguration?.text == "No Local Files Yet" }
        try await capture("14-downloads-empty")
    }

    func testMacBrowserIsReadOnlyAndOpensNestedDirectories() async throws {
        let runtime = VaultPresentationServices(macDirectory: { path, _, _ in
            if path == nil {
                return VaultMacBrowseResponse(entries: [VaultMacBrowseEntry(path: "/Users/test", name: "Home", isDirectory: true, size: 0, modifiedAt: Date())])
            }
            return VaultMacBrowseResponse(entries: [
                VaultMacBrowseEntry(path: "/Users/test/notes.txt", name: "notes.txt", isDirectory: false, size: 512, modifiedAt: Date()),
                VaultMacBrowseEntry(path: "/Users/test/Documents", name: "Documents", isDirectory: true, size: 0, modifiedAt: Date())])
        })
        let root = VaultMacBrowseViewController(runtime: runtime)
        try await host(root)
        try await waitUntil { root.emptyStateConfiguration == nil }
        try await capture("15-mac-locations")
        root.tableView(root.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        try await Task.sleep(for: .milliseconds(400))
        let folder = try XCTUnwrap(root.navigationController?.topViewController as? VaultMacBrowseViewController)
        try await waitUntil { folder.tableView.numberOfRows(inSection: 0) == 2 }
        XCTAssertEqual(folder.path, "/Users/test")
        let first = folder.tableView(folder.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual((first.contentConfiguration as? UIListContentConfiguration)?.text, "Documents")
        XCTAssertNil(folder.tableView.delegate?.tableView?(folder.tableView, trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 1, section: 0)))
        XCTAssertNil(folder.navigationItem.leftBarButtonItem)
        try await capture("16-mac-files-read-only")
        window?.overrideUserInterfaceStyle = .dark
        try await capture("17-mac-files-dark")
    }

    func testHomeRoutesTransfersAwayFromFileRows() async throws {
        let root = VaultSyncthingHomeViewController(runtime: VaultPresentationServices(connectionStatus: { .connected }))
        try await host(root)
        try await waitUntil { root.tableView.numberOfSections == 3 }
        let activity = root.tableView(root.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual(activity.accessibilityIdentifier, "vault.transfers")
        root.tableView(root.tableView, didSelectRowAt: IndexPath(row: 0, section: 1))
        XCTAssertTrue(root.navigationController?.topViewController is VaultTransfersViewController)
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testConnectedSettingsVisuals() async throws {
        let controller = VaultConnectedSettingsViewController(services: VaultPresentationServices(
            connectionStatus: { .connected },
            pairingSnapshot: { VaultPairingSnapshot(localDeviceID: "local", remoteDeviceID: "remote", remoteName: "MacBook Pro") },
            cachePresentation: { VaultCachePresentation(usedBytes: 24_500_000, quotaBytes: 500_000_000, fileCount: 12) }), pairingHandler: { _ in })
        try await host(controller)
        try await waitUntil { controller.tableView.numberOfSections == 6 }
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 4), 2)
        let image = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 4))
        let video = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 4))
        XCTAssertEqual(image.accessibilityLabel, "Images, JPEG")
        XCTAssertEqual(video.accessibilityLabel, "Videos, MP4")
        try await capture("10-connected-settings")
    }
    func testMacDiskUsageAppearsForEveryLunaMacClient() async throws {
        let volume = LunaMacStorageVolume(id: "disk", name: "Macintosh HD", totalBytes: 1_000_000_000_000,
            freeBytes: 400_000_000_000, categories: [.music: 120_000_000_000, .photos: 60_000_000_000,
                .videos: 40_000_000_000, .files: 20_000_000_000, .code: 8_000_000_000, .appData: 2_000_000_000])
        for client in LunaMacClient.allCases {
            let controller = LunaMacConnectionViewController(services: VaultPresentationServices(
                macStorage: { _ in LunaMacStorageSnapshot(volumes: [volume]) },
                connectionStatus: { .connected },
                pairingSnapshot: { VaultPairingSnapshot(localDeviceID: "local", remoteDeviceID: "remote") }),
                client: client, pairingHandler: { _ in })
            try await host(controller)
            try await waitUntil {
                guard controller.tableView.numberOfSections > 1 else { return false }
                let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
                return cell.contentView.subviews.contains { $0.accessibilityIdentifier == "luna.mac.storage.volume" }
            }
            XCTAssertEqual(controller.tableView.numberOfSections, client == .vault ? 6 : 3)
            XCTAssertEqual(controller.tableView(controller.tableView, titleForHeaderInSection: 1), "Mac Disk Usage")
            controller.tableView.scrollToRow(at: IndexPath(row: 0, section: 1), at: .top, animated: false)
            try await capture("mac-storage-" + client.rawValue)
            if client == .vault {
                controller.traitOverrides.userInterfaceStyle = .dark
                controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
                try await host(controller, size: CGSize(width: 320, height: 568))
                controller.tableView.scrollToRow(at: IndexPath(row: 0, section: 1), at: .top, animated: false)
                try await capture("mac-storage-small-large-text-dark")
            }
        }
    }

    func testMacStorageShowsEachVolumeSeparately() async throws {
        let volumes = [
            LunaMacStorageVolume(id: "internal", name: "Macintosh HD", totalBytes: 1_000_000, freeBytes: 400_000, categories: [.appData: 1_000]),
            LunaMacStorageVolume(id: "external", name: "External Library", totalBytes: 2_000_000, freeBytes: 800_000, categories: [.music: 500_000])
        ]
        let controller = LunaMacConnectionViewController(services: VaultPresentationServices(
            macStorage: { _ in LunaMacStorageSnapshot(volumes: volumes) },
            connectionStatus: { .connected },
            pairingSnapshot: { VaultPairingSnapshot(localDeviceID: "local", remoteDeviceID: "remote") }),
            client: .vault, pairingHandler: { _ in })
        try await host(controller)
        try await waitUntil { controller.tableView.numberOfSections == 6 && controller.tableView.numberOfRows(inSection: 1) == 3 }
        for row in 0..<2 {
            let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: row, section: 1))
            XCTAssertTrue(cell.contentView.subviews.contains { $0.accessibilityIdentifier == "luna.mac.storage.volume" })
        }
    }

    func testOfflineMacStorageDoesNotInventZeroUsage() async throws {
        let controller = LunaMacConnectionViewController(services: VaultPresentationServices(
            macStorage: { _ in XCTFail("Offline settings must not start a storage request"); throw TestError.failed },
            connectionStatus: { .offline },
            pairingSnapshot: { VaultPairingSnapshot(localDeviceID: "local", remoteDeviceID: "remote") }),
            client: .vault, pairingHandler: { _ in })
        try await host(controller)
        try await waitUntil { controller.tableView.numberOfSections == 6 }
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual((cell.contentConfiguration as? UIListContentConfiguration)?.secondaryText, "Connect to your Mac to see disk usage.")
    }

    func testMacStorageFailureKeepsConnectionSettingsUsable() async throws {
        let controller = LunaMacConnectionViewController(services: VaultPresentationServices(
            macStorage: { _ in throw VaultMacBrowseError("Update Luna Mac to see disk usage.") },
            connectionStatus: { .connected },
            pairingSnapshot: { VaultPairingSnapshot(localDeviceID: "local", remoteDeviceID: "remote") }),
            client: .music, pairingHandler: { _ in })
        try await host(controller)
        try await waitUntil {
            guard controller.tableView.numberOfSections == 3 else { return false }
            let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
            return (cell.contentConfiguration as? UIListContentConfiguration)?.secondaryText == "Update Luna Mac to see disk usage."
        }
        let reconnect = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(reconnect.accessibilityLabel, "Reconnect")
    }

    func testSetupAdaptsToLargeTextAndSmallScreen() async throws {
        let controller = VaultConnectedSettingsViewController(services: VaultPresentationServices(), pairingHandler: { _ in })
        try await host(controller)
        try await waitUntil { controller.tableView.numberOfSections == 1 }
        try await capture("11-setup-standard")
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        try await host(controller, size: CGSize(width: 320, height: 568))
        try await waitUntil { controller.tableView.numberOfSections == 1 }
        try await capture("11-setup-small-large-text")
        controller.tableView.scrollToRow(at: IndexPath(row: 1, section: 0), at: .bottom, animated: false)
        try await capture("12-setup-small-large-text-action")
        XCTAssertGreaterThan(controller.tableView.contentSize.height, controller.tableView.bounds.height)
    }
}
private enum TestError: Error { case failed }
private actor SearchProbe {
    var count = 0
    func search(_ query: String) async -> [VaultPresentedFile] {
        count += 1
        if query == "slow" { try? await Task.sleep(for: .milliseconds(450)) }
        return [VaultPresentedFile(id: query, name: query + ".txt", path: query, modifiedAt: Date())]
    }
}
