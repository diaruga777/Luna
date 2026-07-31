//
//  DownloaderOnboardingDemoSave.swift
//  Luna
//

import LunaMediaDownload
import LunaModels
import LunaStorage
import Foundation

enum DownloaderOnboardingDemoSave {
    /// A media save lands in both stores (the reading-list item at ingest, the
    /// file in `SavedMediaStore`), so the eviction watch covers both.
    static let service = OnboardingTemporarySave(
        install: install,
        cleanup: cleanup,
        changeNotifications: [.readingListChanged, .savedMediaChanged],
        storedIdentifiers: {
            Set(ReadingListStore.shared.items().map(\.id))
                .union(SavedMediaStore.shared.items().map(\.id))
        })

    private static let sourceURL = "https://instatok.local/@moonwatch/eclipse"

    private static func install() -> Bool {
        let registry = AppOnboardingStore.shared
        let store = SavedMediaStore.shared
        guard store.item(forURLString: sourceURL) == nil else {
            // A matching user save is already real content, but is not ours to
            // claim or delete when the app backgrounds.
            registry.clearTemporarySaveIdentifier()
            return true
        }
        guard let bundled = Bundle.main.url(
            forResource: "LunaEclipse", withExtension: "mp4")
        else { return false }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("luna-onboarding-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.copyItem(at: bundled, to: staging)
            let item = try store.addDownloadedFile(
                staging,
                kind: .video,
                sourceURLString: sourceURL,
                title: "Total Lunar Eclipse",
                creator: "@moonwatch",
                fileExtension: "mp4")
            registry.recordTemporarySave(identifier: item.id)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
    }

    private static func cleanup() {
        let registry = AppOnboardingStore.shared
        defer { registry.clearTemporarySaveIdentifier() }
        guard let identifier = registry.temporarySaveIdentifier,
              let item = SavedMediaStore.shared.items().first(where: {
                  $0.id == identifier
              })
        else { return }
        SavedMediaStore.shared.delete(item)
    }
}
