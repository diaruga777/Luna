//
//  LiveMediaDownloadActivity.swift
//  Luna
//

import LunaAppConfig
import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
public struct LiveMediaDownloadAttributes: ActivityAttributes {
    public enum MediaKind: String, Codable, Hashable {
        case image
        case animatedImage
        case video
        case unknown
    }

    public struct ContentState: Codable, Hashable {
        public enum Phase: String, Codable, Hashable {
            case resolving
            case downloading
            case waiting
            case suspended
            case saving
            case finished
            case failed
        }

        public var phase: Phase
        public var progress: Double
        public var mediaKind: MediaKind
        public var message: String
        public var thumbnailFileName: String?
        public var actionURLString: String?
        public var suspendDeadline: Date?

        public init(
            phase: Phase,
            progress: Double,
            mediaKind: MediaKind,
            message: String,
            thumbnailFileName: String? = nil,
            actionURLString: String? = nil,
            suspendDeadline: Date? = nil
        ) {
            self.phase = phase
            self.progress = min(1, max(0, progress))
            self.mediaKind = mediaKind
            self.message = message
            self.thumbnailFileName = thumbnailFileName
            self.actionURLString = actionURLString
            self.suspendDeadline = suspendDeadline
        }
    }

    public var jobID: String
    public var sourceURLString: String
    public var title: String

    public init(jobID: String, sourceURLString: String, title: String) {
        self.jobID = jobID
        self.sourceURLString = sourceURLString
        self.title = title
    }
}
#endif

public extension MediaAsset.Kind {
    var liveActivityKind: String {
        switch self {
        case .image: return "image"
        case .gif: return "animatedImage"
        case .video: return "video"
        case .audio: return "audio"
        }
    }
}

public enum LiveMediaDownloadAssets {
    public static func thumbnailURL(fileName: String) -> URL {
        let fallback = FileManager.default.temporaryDirectory
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) ?? fallback
        let dir = base.appendingPathComponent("LiveMediaDownloads", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }
}
