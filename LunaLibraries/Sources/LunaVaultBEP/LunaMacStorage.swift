import Foundation

/// Read-only storage reporting on the approved, authenticated Luna Mac stream.
public enum LunaMacStorageProtocol {
    public static let folder = "luna-storage-v1"
    public static let maximumResponseSize = 64 * 1024
}

public enum LunaMacStorageCategory: String, Codable, CaseIterable, Sendable {
    case music, photos, videos, files, code, appData

    public var title: String {
        switch self {
        case .music: return "Music"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .files: return "Files"
        case .code: return "Code & Builds"
        case .appData: return "App Data"
        }
    }
}

public struct LunaMacStorageVolume: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let categories: [LunaMacStorageCategory: Int64]

    public init(id: String, name: String, totalBytes: Int64, freeBytes: Int64,
                categories: [LunaMacStorageCategory: Int64]) {
        self.id = id; self.name = name; self.totalBytes = totalBytes
        self.freeBytes = freeBytes; self.categories = categories
    }

    public var lunaBytes: Int64 { categories.values.reduce(0, +) }
    public var usedBytes: Int64 { totalBytes - freeBytes }
    public var otherBytes: Int64 { max(0, usedBytes - lunaBytes) }

    public func validate() throws {
        guard totalBytes > 0, freeBytes >= 0, freeBytes <= totalBytes else {
            throw VaultMacBrowseError("The Mac returned invalid disk capacity.")
        }
        var sum: Int64 = 0
        for bytes in categories.values {
            let (next, overflow) = sum.addingReportingOverflow(bytes)
            guard bytes >= 0, !overflow else { throw VaultMacBrowseError("The Mac returned invalid storage usage.") }
            sum = next
        }
        guard sum <= usedBytes else {
            throw VaultMacBrowseError("Luna’s allocated files exceed the disk’s used space. Shared APFS blocks prevent an accurate breakdown.")
        }
    }
}

public struct LunaMacStorageSnapshot: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let volumes: [LunaMacStorageVolume]
    public init(measuredAt: Date = Date(), volumes: [LunaMacStorageVolume]) {
        self.measuredAt = measuredAt; self.volumes = volumes
    }
    public func validate() throws {
        guard !volumes.isEmpty, volumes.count <= 32, Set(volumes.map(\.id)).count == volumes.count else {
            throw VaultMacBrowseError("The Mac returned invalid storage information.")
        }
        for volume in volumes { try volume.validate() }
    }
}

public struct LunaMacStorageResponse: Codable, Sendable {
    public let snapshot: LunaMacStorageSnapshot?
    public let error: String?
    public init(snapshot: LunaMacStorageSnapshot? = nil, error: String? = nil) {
        self.snapshot = snapshot; self.error = error
    }
}
