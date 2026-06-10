//
//  BackgroundPhotoScanRunner.swift
//  BackgroundResourceUploadExtension
//

import CoreGraphics
import Foundation
import Photos
import UIKit
import UserNotifications

/// One bounded batch of "react to new photos": find images added since the last
/// scan, downscale + luminance-check each for the pocket criterion, notify on a hit,
/// and persist how far we got (App Group). Returns whether more remain so the system
/// re-invokes until caught up. Self-contained and allocation-light to stay under the
/// extension's memory ceiling.
struct BackgroundPhotoScanRunner {

    private let appGroupID = "group.com.hpiddy.clip"
    private let lastScanKey = "clip.bgLastScanDate"
    private let lastTriggerKey = "clip.lastPocketTrigger"
    private let maxAssetsPerInvocation = 8

    func runBatch() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }

        let defaults = UserDefaults(suiteName: appGroupID)
        let lastScan = (defaults?.object(forKey: lastScanKey) as? Date) ?? Date()

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate > %@",
            PHAssetMediaType.image.rawValue, lastScan as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        guard assets.count > 0 else { return false }

        let batch = min(assets.count, maxAssetsPerInvocation)
        var newestSeen = lastScan
        for index in 0..<batch {
            let asset = assets.object(at: index)
            if let created = asset.creationDate, created > newestSeen { newestSeen = created }
            if let image = await loadThumbnail(asset), isPocket(image) {
                postPocketNotification()
                defaults?.set(Date().timeIntervalSince1970, forKey: lastTriggerKey)
            }
        }
        defaults?.set(newestSeen, forKey: lastScanKey)
        return assets.count > batch
    }

    // MARK: - Image load

    private func loadThumbnail(_ asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false  // background: don't pull from iCloud
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 64, height: 64),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    // MARK: - Pocket detection (luminance + uniformity)

    /// True when the frame is plainly dark, or dim and very uniform (a covered lens),
    /// mirroring the capture extension's PocketSceneAnalyzer.
    private func isPocket(_ cgImage: CGImage) -> Bool {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var sum = 0.0, sumSquares = 0.0, darkCount = 0
        let samples = side * side
        for i in 0..<samples {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            sum += luminance
            sumSquares += luminance * luminance
            if luminance < 0.16 { darkCount += 1 }
        }
        let n = Double(samples)
        let brightness = sum / n
        let stdDev = max(0, sumSquares / n - brightness * brightness).squareRoot()
        let darkFraction = Double(darkCount) / n

        let plainlyDark = brightness <= 0.10 && darkFraction >= 0.80
        let dimAndFlat = stdDev <= 0.06 && brightness <= 0.35
        return plainlyDark || dimAndFlat
    }

    // MARK: - Notify

    private func postPocketNotification() {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Clip"
        content.body = "Pocket photo detected"
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "clip.pocket.bg.\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }
}
