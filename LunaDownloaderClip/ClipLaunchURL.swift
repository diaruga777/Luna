//
//  ClipLaunchURL.swift
//  LunaDownloaderClip
//

import Foundation

enum ClipLaunchURL {
    static func sourceURL(from launchURL: URL) -> URL? {
        guard let components = URLComponents(url: launchURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        for name in ["url", "source", "sourceURL", "u"] {
            if let value = components.queryItems?.first(where: { $0.name == name })?.value,
               let url = URL(string: value),
               isWebURL(url) {
                return url
            }
        }

        if launchURL.path == "/download",
           let fragment = components.fragment?.removingPercentEncoding,
           let url = URL(string: fragment),
           isWebURL(url) {
            return url
        }

        return isWebURL(launchURL) && launchURL.host?.localizedCaseInsensitiveContains("luna") == false
            ? launchURL
            : nil
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
