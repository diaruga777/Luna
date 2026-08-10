//
//  MediaAsset+PixelSize.swift
//  LunaMediaResolve
//
//  The clip's shape, as far as the RESOLVE already knows it — which is often
//  before anything has been streamed. Kept here with the resolvers that produce
//  the assets, for the same reason `isDirectlyPlayable` is
//  (`claudedocs/safari-extension.md`): the Safari extension is an adapter and
//  parses nothing itself.
//

import Foundation
import LunaModels

/// A media rendition's pixel dimensions.
public struct MediaPixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Height ÷ width — the one number a player needs to reserve the right box.
    public var aspectHeightOverWidth: Double {
        width > 0 ? Double(height) / Double(width) : 0
    }
}

public extension MediaAsset {
    /// The rendition's size when its own URL states it, else nil.
    ///
    /// Several platforms name the rendition in the path — X serves
    /// `…/vid/avc1/720x1280/<id>.mp4`, and a `WxH` directory is a common CDN
    /// convention generally. That costs nothing to read and lands a whole
    /// network round trip before `loadedmetadata` does, which is the difference
    /// between a popup that opens at the clip's shape and one that visibly
    /// re-shapes itself under the user's thumb.
    ///
    /// Deliberately conservative: only a path COMPONENT that is entirely
    /// `<digits>x<digits>` counts, both within plausible video bounds, and the
    /// last such component wins (the most specific one). A platform that names
    /// nothing simply answers nil and the player falls back to what it always
    /// did — the page's declared dimensions, then the element's own metadata.
    var declaredPixelSize: MediaPixelSize? {
        MediaPixelSize.inPath(of: url)
    }
}

public extension MediaPixelSize {
    /// The bounds a `WxH` path component has to fall inside to be read as a
    /// video size rather than as an id that happens to contain an `x`.
    static let plausibleRange = 16...16384

    static func inPath(of url: URL) -> MediaPixelSize? {
        var found: MediaPixelSize?
        for component in url.pathComponents {
            let halves = component.split(separator: "x", omittingEmptySubsequences: false)
            guard halves.count == 2,
                  let width = Int(halves[0]), let height = Int(halves[1]),
                  halves[0].allSatisfy(\.isNumber), halves[1].allSatisfy(\.isNumber),
                  plausibleRange.contains(width), plausibleRange.contains(height)
            else { continue }
            found = MediaPixelSize(width: width, height: height)
        }
        return found
    }
}
