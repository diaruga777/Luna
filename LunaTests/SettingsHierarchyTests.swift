//
//  SettingsHierarchyTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// Pins whether Settings believes a sending account is connected, so the
/// email-gated rows can be asserted either way without the App Group.
struct StubEmailAccountStatus: EmailAccountStatusProviding {
    let isConnected: Bool

    var isEmailAccountConnected: Bool { isConnected }
}

@MainActor
final class SettingsHierarchyTests: XCTestCase {
    private var window: UIWindow?
    private var oldCatalog: (any PluginCatalogProviding)?
    private var catalog: SettingsPluginCatalog!

    override func setUp() {
        super.setUp()
        oldCatalog = PluginPlatformServices.catalog
        catalog = SettingsPluginCatalog()
        catalog.items = [plugin(id: "test.video", produces: [.media])]
        PluginPlatformServices.catalog = catalog
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        PluginPlatformServices.catalog = oldCatalog
        catalog = nil
        super.tearDown()
    }

    func testVideoSettingsFollowInstalledMediaPluginsOnReturn() {
        catalog.items = [plugin(id: "test.transcript", produces: [.article])]
        let screen = SettingsViewController()
        window = UITestSupport.host(UINavigationController(rootViewController: screen))
        XCTAssertFalse(rowTitles(screen).contains("Video"))
        XCTAssertTrue(rowTitles(screen).contains("Audio"))

        catalog.items.append(plugin(id: "test.video", produces: [.media], status: .disabled))
        screen.viewWillAppear(false)
        XCTAssertTrue(rowTitles(screen).contains("Video"))

        catalog.items = []
        screen.viewWillAppear(false)
        XCTAssertFalse(rowTitles(screen).contains("Video"))
    }

    func testSafariVideoPlayerIsHiddenWithoutAMediaPlugin() {
        catalog.items = []
        let screen = ShortcutSettingsScreen(showsShortcutSetup: false)
        window = UITestSupport.host(screen)
        XCTAssertEqual(sectionTitles(screen), ["Luna Button", "Cookie Popups"])
    }

    func testEreaderControlsRequireTheirOwnInstalledPlugin() {
        catalog.items = []
        XCTAssertFalse(PluginFeatureAvailability.isDestinationAvailable(ArticleDestinationID.xteink))
        XCTAssertFalse(PluginFeatureAvailability.hasKindlePlugin)
        XCTAssertTrue(PluginFeatureAvailability.isDestinationAvailable("test.other"))
        let shortcut = ShortcutSettingsScreen(showsShortcutSetup: true)
        window = UITestSupport.host(shortcut)
        let section = sectionTitles(shortcut).firstIndex(of: "Double Save Action")!
        let cell = shortcut.tableView(shortcut.tableView, cellForRowAt: IndexPath(row: 0, section: section))
        let picker = cell.accessoryView as! UIButton
        XCTAssertFalse(picker.menu!.children.contains { $0.title == "Send to Kindle" })

        let email = EmailAndKindleSettingsScreen()
        window = UITestSupport.host(email)
        XCTAssertFalse(rowTitles(email).contains(L10n.string("Settings_email_autoSendToKindleLabel")))
        let countWithoutKindle = email.tableView.numberOfRows(inSection: 1)

        catalog.items = [plugin(id: "app.luna.xteink", produces: [])]
        XCTAssertTrue(PluginFeatureAvailability.isDestinationAvailable(ArticleDestinationID.xteink))
        XCTAssertFalse(PluginFeatureAvailability.hasKindlePlugin)
        catalog.items = [plugin(id: "app.luna.kindle", produces: [], status: .disabled)]
        XCTAssertTrue(PluginFeatureAvailability.hasKindlePlugin)
        XCTAssertFalse(PluginFeatureAvailability.isDestinationAvailable(ArticleDestinationID.xteink))
        email.tableView.reloadData()
        XCTAssertEqual(email.tableView.numberOfRows(inSection: 1), countWithoutKindle + 1)
        XCTAssertTrue(rowTitles(email).contains(L10n.string("Settings_email_autoSendToKindleLabel")))
    }

    private func plugin(
        id: String, produces: [PluginModelKind], status: PluginStatus = .enabled
    ) -> PluginListing {
        PluginListing(
            summary: PluginSummary(
                id: id, name: id, version: "1.0.0", priority: 0, matchesAnyHost: true,
                hostPatterns: [], produces: produces, hooks: [], export: nil, isBundled: false),
            description: nil, status: status, capabilities: [], runsInBackground: false, settings: [])
    }

    private func rowTitles(_ screen: UITableViewController) -> [String] {
        (0..<screen.tableView.numberOfSections).flatMap { section in
            (0..<screen.tableView.numberOfRows(inSection: section)).compactMap {
                rowTitle(screen, row: $0, section: section)
            }
        }
    }

    func testReaderIncludesPreloadControlsWithoutSavesRowDisplayToggles() {
        let screen = ReaderSettingsScreen()
        window = UITestSupport.host(screen)

        XCTAssertEqual(screen.tableView.numberOfSections, 2)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 5)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 1), 2)
        XCTAssertEqual(rowTitle(screen, row: 0, section: 1), "Only on Wi-Fi")
        XCTAssertEqual(rowTitle(screen, row: 1, section: 1), "Preload Depth")

        let allTitles = (0..<screen.tableView.numberOfSections).flatMap { section in
            (0..<screen.tableView.numberOfRows(inSection: section)).compactMap {
                rowTitle(screen, row: $0, section: section)
            }
        }
        XCTAssertFalse(allTitles.contains("Reading Time"))
        XCTAssertFalse(allTitles.contains("Reading Progress"))
    }

    func testAudioIncludesVoiceStatusAndInstallRowsInline() {
        let screen = AudioSettingsScreen()
        window = UITestSupport.host(screen)

        XCTAssertEqual(screen.tableView.numberOfSections, 3)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 2), 2)
        XCTAssertEqual(rowTitle(screen, row: 1, section: 2), "Install Enhanced Voices")
    }

    func testVideoUsesTwoPickersAndAProgressToggle() {
        let screen = DownloadsSettingsScreen()
        window = UITestSupport.host(screen)

        XCTAssertEqual(screen.tableView.numberOfSections, 3)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 1)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 1), 1)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 2), 1)
        XCTAssertEqual(rowTitle(screen, row: 0, section: 0), "Begin Streaming")
        XCTAssertEqual(rowTitle(screen, row: 0, section: 1), "Storage")
        XCTAssertEqual(rowTitle(screen, row: 0, section: 2), "Notify save progress")
        XCTAssertEqual(
            (screen.tableView(screen.tableView, cellForRowAt: IndexPath(row: 0, section: 2)).accessoryView
                as? UISwitch)?.isOn,
            false)
    }

    func testImportExportIncludesEpubAndIsReachableFromTheTopLevel() {
        let screen = ImportExportSettingsScreen()
        window = UITestSupport.host(screen)

        XCTAssertEqual(screen.tableView.numberOfSections, 1)
        XCTAssertEqual(rowTitle(screen, row: 0, section: 0), "Export Links")
        XCTAssertEqual(rowTitle(screen, row: 1, section: 0), "Import Links")
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 3)
        XCTAssertEqual(rowTitle(screen, row: 2, section: 0), "Import EPUB Book")

        let top = SettingsViewController(emailStatus: StubEmailAccountStatus(isConnected: true))
        window = UITestSupport.host(UINavigationController(rootViewController: top))
        let titles = (0..<top.tableView.numberOfRows(inSection: 0)).compactMap {
            rowTitle(top, row: $0, section: 0)
        }
        XCTAssertTrue(titles.contains("Import & Export"), "\(titles)")
    }

    func testKindleForwardingDoesNotExposeDoubleSaveMode() {
        let screen = AutoSendBySourceScreen(
            destinationID: "test-kindle", destinationName: "Kindle")
        window = UITestSupport.host(screen)

        let cell = screen.tableView(
            screen.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        let modeButton = try! XCTUnwrap(cell.accessoryView as? UIButton)
        let modeTitles = modeButton.menu?.children.compactMap {
            ($0 as? UIAction)?.title
        }
        XCTAssertEqual(modeTitles, ["Off", "All Saved Articles"])
    }

    /// Central Luna sends to Kindle through the bundled plugin, so its Kindle
    /// settings live under Plugins and the top level has no Kindle row of its
    /// own; the Reader keeps the Swift row and its email prerequisite.
    func testTopLevelHidesDiagnosticsAndKindleAndShowsPlugins() {
        let screen = SettingsViewController(emailStatus: StubEmailAccountStatus(isConnected: false))
        let nav = UINavigationController(rootViewController: screen)
        window = UITestSupport.host(nav)

        let titles = (0..<screen.tableView.numberOfRows(inSection: 0)).compactMap {
            rowTitle(screen, row: $0, section: 0)
        }
        XCTAssertTrue(titles.contains("Email"))
        XCTAssertTrue(titles.contains("Plugins"))
        XCTAssertFalse(titles.contains("Kindle"))
        XCTAssertFalse(titles.contains("Saves"))
        XCTAssertFalse(titles.contains("Diagnostics"))
    }

    /// The Safari extension needs no particular OS or hardware, so its sections
    /// survive on a device with no Action Button to assign the shortcut to —
    /// and the screen renames itself to what is left of it.
    ///
    /// What is left is the extension's own three toggles, and each is gated on a
    /// KIND rather than on the device: the suggestion pill only fires on article
    /// pages and cookie auto-decline is the article apps' choice to make
    /// (`handlesArticles`), while the in-page video player only opens on media
    /// pages (`handlesMedia`). The test host is the CENTRAL Luna app, which
    /// handles both kinds, so all three stand here; Reader would show "Luna
    /// Button" and "Cookie Popups" and the Downloader only "Video Player" — a
    /// split no in-process test can reach, since `LunaApp.current` comes from the
    /// host bundle id.
    func testWithoutShortcutHardwareTheKindGatedSafariSectionsRemain() {
        let screen = ShortcutSettingsScreen(showsShortcutSetup: false)
        window = UITestSupport.host(screen)

        XCTAssertTrue(LunaApp.current.handlesArticles && LunaApp.current.handlesMedia)
        XCTAssertEqual(screen.tableView.numberOfSections, 3)
        XCTAssertEqual(
            sectionTitles(screen), ["Luna Button", "Cookie Popups", "Video Player"])
        XCTAssertEqual(
            ShortcutSettingsScreen.screenTitle(showsShortcutSetup: false), "Safari")
    }

    func testShortcutCapableDeviceKeepsEveryShortcutSection() {
        let screen = ShortcutSettingsScreen(showsShortcutSetup: true)
        window = UITestSupport.host(screen)

        XCTAssertEqual(
            sectionTitles(screen),
            [
                "Luna Button", "Cookie Popups", "Video Player", "Apple Intelligence",
                "Double Save Action", "Action Button",
            ])
        XCTAssertEqual(
            ShortcutSettingsScreen.screenTitle(showsShortcutSetup: true),
            "Safari & One-click save")
    }

    /// The Cookie Popups cell, both directions. The switch must READ the setting
    /// (shipped default ON, with nothing written) and WRITE it — the appex reads the
    /// same App Group key as a bare literal, so a cell wired to the wrong property
    /// would look perfect and change nothing in Safari.
    func testCookiePopupsToggleReadsAndWritesTheSharedSetting() {
        let restore = UserDefaults(suiteName: SavesStore.appGroupID)?
            .object(forKey: SafariSuggestionSettings.cookieAutoDeclineKey)
        defer {
            let defaults = UserDefaults(suiteName: SavesStore.appGroupID)
            if let restore {
                defaults?.set(restore, forKey: SafariSuggestionSettings.cookieAutoDeclineKey)
            } else {
                defaults?.removeObject(forKey: SafariSuggestionSettings.cookieAutoDeclineKey)
            }
        }
        UserDefaults(suiteName: SavesStore.appGroupID)?
            .removeObject(forKey: SafariSuggestionSettings.cookieAutoDeclineKey)

        let screen = ShortcutSettingsScreen(showsShortcutSetup: false)
        window = UITestSupport.host(screen)
        let section = try! XCTUnwrap(sectionTitles(screen).firstIndex(of: "Cookie Popups"))
        let cell = screen.tableView(
            screen.tableView, cellForRowAt: IndexPath(row: 0, section: section))
        let toggle = try! XCTUnwrap(cell.accessoryView as? UISwitch)
        XCTAssertTrue(toggle.isOn, "an absent key must read as ON")

        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        XCTAssertFalse(SafariSuggestionSettings.cookieAutoDeclineEnabled)

        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        XCTAssertTrue(SafariSuggestionSettings.cookieAutoDeclineEnabled)
    }

    func testSettingsHasFiveTapDiagnosticsGesture() {
        let screen = SettingsViewController(emailStatus: StubEmailAccountStatus(isConnected: false))
        window = UITestSupport.host(screen)

        XCTAssertTrue(screen.tableView.gestureRecognizers?.contains {
            ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 5
        } ?? false)
    }

    private func sectionTitles(_ screen: UITableViewController) -> [String] {
        (0..<screen.tableView.numberOfSections).compactMap {
            screen.tableView(screen.tableView, titleForHeaderInSection: $0)
        }
    }

    private func rowTitle(
        _ screen: UITableViewController, row: Int, section: Int
    ) -> String? {
        let cell = screen.tableView(
            screen.tableView, cellForRowAt: IndexPath(row: row, section: section))
        return (cell.contentConfiguration as? UIListContentConfiguration)?.text
    }
}

private final class SettingsPluginCatalog: PluginCatalogProviding {
    var items: [PluginListing] = []
    func listings() -> [PluginListing] { items }
    func listing(pluginID: String) -> PluginListing? { items.first { $0.summary.id == pluginID } }
    func sourceText(pluginID: String) -> String? { nil }
    func setEnabled(_ enabled: Bool, pluginID: String) throws {}
    func setAutoShowSafariPlayer(_ enabled: Bool, pluginID: String) throws {}
    func delete(pluginID: String) throws {}
}
