//
//  KindWiring+PriceTracker.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors,
//  ingestor handlers, and UI/lifecycle seams this app's target links. EXACTLY
//  ONE KindWiring variant is compiled into each app target (the other variants
//  are excluded via the synchronized group's per-target membership exceptions)
//  — the registries and the static lifecycle API below mirror the link set.
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPriceIngest
import LunaPriceUI
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import UIKit

enum KindWiring {
    private static let onboardingProductURL = "https://amayzon.local/eyephone-air"

    @MainActor
    static func install() {
        #if DEBUG
        ReaderOnboardingStore.shared.resetIfRequested()
        #endif
        ReaderOnboardingWiring.installLaunchTransition = { window in
            ReaderLaunchTransition.install(in: window)
        }
        ReaderOnboardingWiring.makeCompletedRootViewController = {
            makeCompletedRootViewController()
        }
        ReaderOnboardingWiring.installTemporaryDemoSave = {
            installTemporaryDemoProduct()
        }
        ReaderOnboardingWiring.cleanupTemporaryDemoSave = {
            cleanupTemporaryDemoProduct()
        }

        IngestKindProcessors.product = ProductIngestProcessor()
        IngestorKindHandlers.product = ProductKindHandler()
        // No price-graph email snapshot: Price Tracker shares a tracker as its
        // product link, never as a Luna email (see `LunaApp.sharesByEmail`).

        // Install the in-app "Read instead" behavior for the price-tracking editor
        // (shared with the extensions, which can't reference the ingestor): a
        // forced-article re-save, no re-detection back into a tracker.
        PriceTrackingViewController.defaultSaveAsArticle = { urlString in
            Task { await ReadingListIngestor.shared.saveAsArticle(urlString: urlString) }
        }
        // Price Tracker "no price" → "Ask Apple Intelligence" resolver (URL
        // Rescue Phase 6 UI).
        PriceTrackingViewController.intelligentPriceResolver = { urlString in
            guard let info = await URLRescueWiring.rescueProductInfo(urlString: urlString)
            else { return nil }
            return PriceTrackingViewController.ResolvedPrice(
                amount: info.priceAmount, currency: info.priceCurrency)
        }
    }

    // MARK: - Root UI shape

    /// The Price Tracker uses the same root card deck + arc trays as Reader and
    /// Downloader, without the article app's audio mini-player host.
    static func makeRootViewController() -> UIViewController {
        let content: UIViewController = ReaderOnboardingStore.shared.isCompleted
            ? PriceTrackerCardsViewController()
            : ReaderOnboardingViewController()
        return UINavigationController(rootViewController: content)
    }

    private static func makeCompletedRootViewController() -> UIViewController {
        UINavigationController(rootViewController: PriceTrackerCardsViewController())
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        root as? UINavigationController
    }

    /// Price Tracker adds no kind rows — the universal tail is the whole menu.
    static func settingsCategories() -> [SettingsCategory] { [] }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
        ReaderOnboardingWiring.cleanupTemporaryDemoSave?()
    }

    static func appDidEnterBackground() {
        ReaderOnboardingWiring.cleanupTemporaryDemoSave?()
    }

    static func sceneDidForeground() {}

    static func readingListDidChange() {}

    static func wifiBecameAvailable() {}

    /// Price Tracker handles no articles — ereader sends are never pending here.
    static func retryPendingArticleSends() {}

    static func resumeUnfinishedMediaDownloads() async {}

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        // No media kind → no background URLSession to reattach; complete the
        // callback immediately so the system isn't left waiting.
        completionHandler()
    }

    /// Runs one price-refresh pass and returns the processed-tracker count.
    /// Non-nil only in product-handling apps; its presence is what arms the
    /// price-refresh BGTask registration/scheduling in AppDelegate.
    static let priceRefreshRunner: (() async -> Int)? = {
        await PriceRefreshCoordinator.shared.refreshAndNotify().count
    }

    // MARK: - Onboarding demonstration save

    private static func installTemporaryDemoProduct() {
        let registry = ReaderOnboardingStore.shared
        let store = ReadingListStore.shared
        guard store.item(forURLString: onboardingProductURL) == nil else {
            registry.clearTemporarySaveIdentifier()
            return
        }

        let item = store.add(urlString: onboardingProductURL, source: .manual)
        let imageFileName = "\(item.id.uuidString)-onboarding-eyephone.png"
        let imageURL = store.articlesDirectory.appendingPathComponent(imageFileName)
        try? makeEyePhoneImage().pngData()?.write(to: imageURL, options: .atomic)

        var tracker = PriceTracker(
            productName: "eyePhone Air — 256 GB, Moonmist",
            firstStoreURL: onboardingProductURL,
            price: 799,
            currency: "USD",
            brand: "Pearless Devices",
            productID: "EP-AIR-256-MOONMIST",
            imageFileName: FileManager.default.fileExists(atPath: imageURL.path)
                ? imageFileName
                : nil)
        tracker.initialPrice = 999
        guard store.savePriceTracker(tracker, for: item.id) != nil else {
            try? FileManager.default.removeItem(at: imageURL)
            store.delete(item)
            return
        }
        registry.recordTemporarySave(identifier: item.id)
    }

    private static func cleanupTemporaryDemoProduct() {
        let registry = ReaderOnboardingStore.shared
        defer { registry.clearTemporarySaveIdentifier() }
        guard let identifier = registry.temporarySaveIdentifier,
              let item = ReadingListStore.shared.item(withID: identifier)
        else { return }
        if let imageFileName = item.priceTracker?.imageFileName {
            try? FileManager.default.removeItem(
                at: ReadingListStore.shared.articlesDirectory
                    .appendingPathComponent(imageFileName))
        }
        ReadingListStore.shared.delete(item)
    }

    /// A deliberately fictional, asymmetric handset: enough product identity
    /// for the saved card, without copying a logo or a real phone silhouette.
    private static func makeEyePhoneImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: 900, height: 900),
            format: format
        ).image { renderer in
            let context = renderer.cgContext
            UIColor(red: 0.93, green: 0.95, blue: 0.97, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 900))

            context.saveGState()
            context.translateBy(x: 450, y: 450)
            context.rotate(by: -0.11)
            let body = UIBezierPath(
                roundedRect: CGRect(x: -205, y: -370, width: 410, height: 740),
                byRoundingCorners: [.topLeft, .topRight, .bottomLeft, .bottomRight],
                cornerRadii: CGSize(width: 86, height: 78))
            UIColor(red: 0.35, green: 0.38, blue: 0.41, alpha: 1).setFill()
            body.fill()

            let screen = UIBezierPath(
                roundedRect: CGRect(x: -191, y: -356, width: 382, height: 712),
                cornerRadius: 72)
            context.saveGState()
            screen.addClip()
            let colors = [
                UIColor(red: 0.54, green: 0.90, blue: 0.83, alpha: 1).cgColor,
                UIColor(red: 0.30, green: 0.43, blue: 0.78, alpha: 1).cgColor,
                UIColor(red: 0.20, green: 0.13, blue: 0.37, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.48, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: -160, y: -330),
                    end: CGPoint(x: 170, y: 340),
                    options: [])
            }
            context.restoreGState()

            UIColor.black.setFill()
            UIBezierPath(
                roundedRect: CGRect(x: -62, y: -330, width: 132, height: 34),
                cornerRadius: 17).fill()
            UIColor(white: 0.08, alpha: 1).setFill()
            UIBezierPath(
                ovalIn: CGRect(x: 120, y: 270, width: 43, height: 47)).fill()
            UIBezierPath(
                ovalIn: CGRect(x: 58, y: 282, width: 40, height: 42)).fill()
            context.restoreGState()
        }
    }

    #if DEBUG
    /// `-openArchive` is an article-app debug tool.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? { nil }

    /// The kind-woven UI-test screen catalog compiles only into the central
    /// Luna app (the UI-test/screenshot host).
    static func uiTestRootViewController(named name: String) -> UIViewController? { nil }
    #endif
}

/// Bridges `IngestorProductHandling` to LunaPriceUI's `ProductTrackerIngestor`.
private struct ProductKindHandler: IngestorProductHandling {
    func ingestProductTracker(
        _ item: ReadingListItem, url: URL, product: ProductInfo, store: ReadingListStore
    ) async {
        await ProductTrackerIngestor.shared.ingest(item, url: url, product: product, store: store)
    }
}
