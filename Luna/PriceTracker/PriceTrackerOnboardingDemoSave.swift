//
//  PriceTrackerOnboardingDemoSave.swift
//  Luna
//

import LunaModels
import LunaStorage
import UIKit

enum PriceTrackerOnboardingDemoSave {
    static let service = OnboardingTemporarySave(
        install: install,
        cleanup: cleanup)

    private static let sourceURL = "https://amayzon.local/eyephone-air"

    private static func install() -> Bool {
        let registry = AppOnboardingStore.shared
        let store = ReadingListStore.shared
        guard store.item(forURLString: sourceURL) == nil else {
            registry.clearTemporarySaveIdentifier()
            return true
        }

        let item = store.add(urlString: sourceURL, source: .manual)
        let imageFileName = "\(item.id.uuidString)-onboarding-eyephone.png"
        let imageURL = store.articlesDirectory.appendingPathComponent(imageFileName)
        let wroteImage: Bool
        if let data = makeEyePhoneImage().pngData() {
            wroteImage = (try? data.write(to: imageURL, options: .atomic)) != nil
        } else {
            wroteImage = false
        }

        var tracker = PriceTracker(
            productName: "eyePhone Air — 256 GB, Moonmist",
            firstStoreURL: sourceURL,
            price: 799,
            currency: "USD",
            brand: "Pearless Devices",
            productID: "EP-AIR-256-MOONMIST",
            imageFileName: wroteImage ? imageFileName : nil)
        tracker.initialPrice = 999
        guard store.savePriceTracker(tracker, for: item.id) != nil else {
            try? FileManager.default.removeItem(at: imageURL)
            store.delete(item)
            return false
        }
        registry.recordTemporarySave(identifier: item.id)
        return true
    }

    private static func cleanup() {
        let registry = AppOnboardingStore.shared
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

    /// Deliberately fictional and asymmetric: enough product identity for the
    /// saved card without copying a logo or real handset silhouette.
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
}
