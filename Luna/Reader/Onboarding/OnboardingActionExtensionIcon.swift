//
//  OnboardingActionExtensionIcon.swift
//  Luna
//

import UIKit

/// The running app's OWN action-extension artwork, read out of the embedded
/// `.action2` appex. It is the util card's utility chip and the save lesson's
/// icon; a generic symbol would read as some other feature entirely.
enum OnboardingActionExtensionIcon {
    static func image(appBundle: Bundle = .main) -> UIImage? {
        guard let plugInsURL = appBundle.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: plugInsURL,
                includingPropertiesForKeys: nil)
        else { return nil }
        for entry in entries where entry.pathExtension == "appex" {
            guard let bundle = Bundle(url: entry),
                  bundle.bundleIdentifier?.hasSuffix(".action2") == true,
                  let image = primaryIcon(in: bundle)
            else { continue }
            return image
        }
        return nil
    }

    private static func primaryIcon(in bundle: Bundle) -> UIImage? {
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons")
            as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        for name in files.reversed() {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
            guard let resources = bundle.resourceURL,
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: resources, includingPropertiesForKeys: nil),
                  let path = entries.first(where: {
                    $0.pathExtension == "png"
                        && $0.deletingPathExtension().lastPathComponent.hasPrefix(name)
                  })?.path,
                  let image = UIImage(contentsOfFile: path)
            else { continue }
            return image
        }
        return nil
    }
}
