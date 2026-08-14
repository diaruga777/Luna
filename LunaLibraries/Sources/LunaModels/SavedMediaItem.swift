//
//  SavedMediaItem.swift
//  LunaModels
//

import Foundation

public struct SavedMediaItem: Codable, Identifiable, Equatable {
    /// Where a saved row's media actually is.
    ///
    /// The Photos case carries only the identifier. Handing the media to Photos
    /// used to need two manifest writes — commit the identifier with the local
    /// names held as `pendingLocal*`, remove those files, then clear the names —
    /// because a crash in between had to be recoverable. The database records that
    /// intent now: the row stops naming the file, the release trigger queues it,
    /// and the reaper unlinks it whenever the process next runs.
    public enum StorageState: Codable, Equatable {
        case undownloaded
        case localFile(fileName: String)
        case photosReference(localIdentifier: String)

        private enum CodingKeys: String, CodingKey {
            case type, fileName, localIdentifier
        }
        private enum Kind: String, Codable { case undownloaded, localFile, photosReference }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .undownloaded:
                self = .undownloaded
            case .localFile:
                self = .localFile(fileName: try container.decode(String.self, forKey: .fileName))
            case .photosReference:
                self = .photosReference(
                    localIdentifier: try container.decode(String.self, forKey: .localIdentifier))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .undownloaded:
                try container.encode(Kind.undownloaded, forKey: .type)
            case .localFile(let fileName):
                try container.encode(Kind.localFile, forKey: .type)
                try container.encode(fileName, forKey: .fileName)
            case .photosReference(let identifier):
                try container.encode(Kind.photosReference, forKey: .type)
                try container.encode(identifier, forKey: .localIdentifier)
            }
        }
    }

    public let id: UUID
    public var sourceURLString: String
    public var title: String?
    public var dateSaved: Date
    /// When non-nil, this row lives in the archive tray. Re-downloads preserve
    /// the value so playback availability never implicitly unarchives it.
    public var archivedAt: Date?
    /// Nil until resolution/download establishes the actual resource type.
    public var kind: MediaAsset.Kind?
    public var storageState: StorageState
    public var thumbnailFileName: String?
    /// The content platform this save belongs to, recognized from
    /// `sourceURLString` (nil for a platform `PlatformRecognizer` doesn't know).
    public var platform: ContentPlatform?
    /// A durable per-platform item id (tweet id, post shortcode, video id, …)
    /// extracted from the URL by `PlatformRecognizer` — used, together with
    /// `platform`, to dedupe saves whose URLs aren't byte-identical (a share
    /// link vs. its resolved permalink, tracking params, etc.).
    public var platformItemID: String?

    /// Title if fetched, else the raw URL as a last resort — the single
    /// fallback rule every UI surface should use instead of reaching for
    /// `sourceURLString` directly.
    public var displayTitle: String { title ?? sourceURLString }

    public var isArchived: Bool { archivedAt != nil }

    public var fileName: String? {
        guard case .localFile(let fileName) = storageState else { return nil }
        return fileName
    }

    public var photosLocalIdentifier: String? {
        guard case .photosReference(let identifier) = storageState else { return nil }
        return identifier
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceURLString, title, dateSaved, archivedAt, kind, storageState, fileName, thumbnailFileName
        case platform, platformItemID
    }

    public init(
        id: UUID, sourceURLString: String, title: String?, dateSaved: Date,
        kind: MediaAsset.Kind?, storageState: StorageState,
        thumbnailFileName: String?,
        platform: ContentPlatform? = nil, platformItemID: String? = nil
    ) {
        self.id = id
        self.sourceURLString = sourceURLString
        self.title = title
        self.dateSaved = dateSaved
        self.archivedAt = nil
        self.kind = kind
        self.storageState = storageState
        self.thumbnailFileName = thumbnailFileName
        self.platform = platform
        self.platformItemID = platformItemID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceURLString = try container.decode(String.self, forKey: .sourceURLString)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        dateSaved = try container.decode(Date.self, forKey: .dateSaved)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        kind = try container.decodeIfPresent(MediaAsset.Kind.self, forKey: .kind)
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        platform = try? container.decodeIfPresent(ContentPlatform.self, forKey: .platform)
        platformItemID = try container.decodeIfPresent(String.self, forKey: .platformItemID)
        if let state = try container.decodeIfPresent(StorageState.self, forKey: .storageState) {
            storageState = state
        } else if let legacyFileName = try container.decodeIfPresent(String.self, forKey: .fileName),
                  !legacyFileName.isEmpty {
            storageState = .localFile(fileName: legacyFileName)
        } else {
            storageState = .undownloaded
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceURLString, forKey: .sourceURLString)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(dateSaved, forKey: .dateSaved)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encode(storageState, forKey: .storageState)
        try container.encodeIfPresent(thumbnailFileName, forKey: .thumbnailFileName)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(platformItemID, forKey: .platformItemID)
        // Continue writing the legacy key for local rows during the rollout.
        try container.encodeIfPresent(fileName, forKey: .fileName)
    }
}
