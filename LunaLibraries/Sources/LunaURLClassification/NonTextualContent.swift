//
//  NonTextualContent.swift
//  Luna
//

import LunaModels
import Foundation

/// A saved URL whose primary content isn't readable article text.
public enum NonTextualContent: Equatable {
    case platform(ContentPlatform, itemID: String?)

    public static func detect(urlString: String) -> NonTextualContent? {
        guard let recognized = PlatformRecognizer.recognize(urlString) else { return nil }
        return .platform(recognized.platform, itemID: recognized.itemID)
    }

    public var platform: ContentPlatform {
        switch self {
        case .platform(let platform, _): return platform
        }
    }

    public var kindLabel: String { platform.displayName }

    public var staticPreviewImageURL: URL? {
        switch self {
        case .platform:
            return nil
        }
    }
}
