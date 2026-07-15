#!/usr/bin/env swift

import AppKit
import Foundation

/// Validates the handmade monochrome PNG used by each action extension.
///
/// The artwork is intentionally maintained directly in the asset catalog. This
/// script must never derive or overwrite it from the full-color application icon.

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let catalogURL = repositoryRoot.appendingPathComponent("SharedIconAssets.xcassets")
private let iconNames = [
    "ActionIconReader",
    "ActionIconDownloader",
    "ActionIconPriceTracker",
]

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

for iconName in iconNames {
    let setURL = catalogURL.appendingPathComponent("\(iconName).appiconset", isDirectory: true)
    let contentsURL = setURL.appendingPathComponent("Contents.json")
    let iconURL = setURL.appendingPathComponent("\(iconName).png")

    guard
        let contentsData = try? Data(contentsOf: contentsURL),
        let contents = try? JSONSerialization.jsonObject(with: contentsData) as? [String: Any],
        let images = contents["images"] as? [[String: Any]],
        images.contains(where: {
            $0["filename"] as? String == "\(iconName).png"
                && $0["idiom"] as? String == "universal"
                && $0["platform"] as? String == "ios"
                && $0["size"] as? String == "1024x1024"
        })
    else {
        fail("\(iconName) must be a modern iOS app-icon set backed by \(iconName).png")
    }

    guard
        let iconData = try? Data(contentsOf: iconURL),
        let bitmap = NSBitmapImageRep(data: iconData),
        bitmap.pixelsWide == 1024,
        bitmap.pixelsHigh == 1024,
        bitmap.hasAlpha
    else {
        fail("\(iconURL.path) must be a transparent 1024x1024 PNG")
    }

    print("Validated \(iconName): \(iconURL.path)")
}
