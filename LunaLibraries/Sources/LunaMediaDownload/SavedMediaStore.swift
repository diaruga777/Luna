//
//  SavedMediaStore.swift
//  Luna
//

import AVFoundation
import ImageIO
import LunaAppConfig
import LunaStorage
import Foundation
import UIKit
import UniformTypeIdentifiers

public struct SavedMediaItem: Codable, Identifiable, Equatable {
    public let id: UUID
    public var sourceURLString: String
    public var title: String?
    public var dateSaved: Date
    public var kind: MediaAsset.Kind
    public var fileName: String
    public var thumbnailFileName: String?

    public var fileURL: URL {
        SavedMediaStore.shared.mediaDirectory.appendingPathComponent(fileName)
    }

    public var thumbnailURL: URL? {
        thumbnailFileName.map { SavedMediaStore.shared.thumbnailDirectory.appendingPathComponent($0) }
    }
}

public final class SavedMediaStore {
    public static let shared = SavedMediaStore()

    private let lock = NSLock()
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init() {}

    public var directory: URL {
        let fallback = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)
            ?? fallback
        let dir = base.appendingPathComponent("SavedMedia", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(dir)
        return dir
    }

    public var mediaDirectory: URL {
        let dir = directory.appendingPathComponent("Files", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var thumbnailDirectory: URL {
        let dir = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var manifestURL: URL {
        directory.appendingPathComponent("savedMedia.json")
    }

    public func items() -> [SavedMediaItem] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked().sorted { $0.dateSaved < $1.dateSaved }
    }

    public func item(id: UUID) -> SavedMediaItem? {
        items().first { $0.id == id }
    }

    public func item(forURLString urlString: String) -> SavedMediaItem? {
        items().first { $0.sourceURLString == urlString }
    }

    @discardableResult
    public func addDownloadedFile(
        _ fileURL: URL,
        kind: MediaAsset.Kind,
        sourceURLString: String,
        title: String?,
        fileExtension ext: String? = nil,
        dateSaved: Date = Date()
    ) throws -> SavedMediaItem {
        let id = UUID()
        let cleanExt = Self.cleanExtension(ext ?? fileURL.pathExtension, kind: kind)
        let fileName = "\(id.uuidString).\(cleanExt)"
        let destination = mediaDirectory.appendingPathComponent(fileName)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: fileURL, to: destination)

        let thumbnailName = makeThumbnail(for: destination, kind: kind, id: id)
        let item = SavedMediaItem(
            id: id,
            sourceURLString: sourceURLString,
            title: title,
            dateSaved: dateSaved,
            kind: kind,
            fileName: fileName,
            thumbnailFileName: thumbnailName)
        lock.lock()
        var items = loadUnlocked()
        let replaced = items.filter { $0.sourceURLString == sourceURLString }
        items.removeAll { $0.sourceURLString == sourceURLString }
        items.append(item)
        saveUnlocked(items)
        lock.unlock()
        for old in replaced {
            try? fm.removeItem(at: old.fileURL)
            if let thumbnailURL = old.thumbnailURL { try? fm.removeItem(at: thumbnailURL) }
        }
        NotificationCenter.default.post(name: .savedMediaChanged, object: nil)
        return item
    }

    public func delete(_ item: SavedMediaItem) {
        lock.lock()
        var items = loadUnlocked()
        items.removeAll { $0.id == item.id }
        saveUnlocked(items)
        lock.unlock()
        try? fm.removeItem(at: item.fileURL)
        if let thumbnailURL = item.thumbnailURL { try? fm.removeItem(at: thumbnailURL) }
        NotificationCenter.default.post(name: .savedMediaChanged, object: nil)
    }

    /// Applies the age-based retention policy. Saved media is app-owned: it is the
    /// Downloader grid's primary content, deleted explicitly from the grid (`delete`)
    /// or aged out here — NOT tied to reading-list membership. (An earlier version
    /// also purged any item whose `sourceURLString` wasn't in the reading list; that
    /// silently deleted freshly-saved media whenever the app's ingest unwrapped/
    /// normalized a URL, since the stored copy keeps the pre-unwrap source URL.)
    public func purgeExpired(now: Date = Date()) {
        lock.lock()
        let items = loadUnlocked()
        let ageExpired: [SavedMediaItem]
        if let days = MediaRetentionSettings.retentionDays {
            let cutoff = now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
            ageExpired = items.filter { $0.dateSaved < cutoff }
        } else {
            ageExpired = []
        }
        let expiredIDs = Set(ageExpired.map(\.id))
        guard !expiredIDs.isEmpty else {
            lock.unlock()
            return
        }
        let kept = items.filter { !expiredIDs.contains($0.id) }
        let expired = items.filter { expiredIDs.contains($0.id) }
        saveUnlocked(kept)
        lock.unlock()
        for item in expired {
            try? fm.removeItem(at: item.fileURL)
            if let thumbnailURL = item.thumbnailURL { try? fm.removeItem(at: thumbnailURL) }
        }
        NotificationCenter.default.post(name: .savedMediaChanged, object: nil)
    }

    private func loadUnlocked() -> [SavedMediaItem] {
        guard let data = try? Data(contentsOf: manifestURL),
              let items = try? decoder.decode([SavedMediaItem].self, from: data)
        else { return [] }
        return items.filter { fm.fileExists(atPath: mediaDirectory.appendingPathComponent($0.fileName).path) }
    }

    private func saveUnlocked(_ items: [SavedMediaItem]) {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: manifestURL, options: [.atomic])
    }

    private func makeThumbnail(for fileURL: URL, kind: MediaAsset.Kind, id: UUID) -> String? {
        let name = "\(id.uuidString).jpg"
        let destination = thumbnailDirectory.appendingPathComponent(name)
        let image: UIImage?
        switch kind {
        case .video:
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            image = (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init(cgImage:))
        case .gif, .image:
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                  ] as CFDictionary)
            else { image = nil; break }
            image = UIImage(cgImage: cgImage)
        }
        guard let data = image?.jpegData(compressionQuality: 0.82) else { return nil }
        try? data.write(to: destination, options: [.atomic])
        return name
    }

    private static func cleanExtension(_ ext: String, kind: MediaAsset.Kind) -> String {
        let cleaned = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        if !cleaned.isEmpty { return String(cleaned.prefix(8)) }
        switch kind {
        case .video: return "mp4"
        case .gif: return "gif"
        case .image: return "jpg"
        }
    }
}

public enum MediaRetentionSettings {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }
    private static let disabledKey = "savedMediaRetention.disabled"
    private static let daysKey = "savedMediaRetention.days"

    public static var retentionDays: Int? {
        get {
            if defaults.bool(forKey: disabledKey) { return nil }
            let stored = defaults.integer(forKey: daysKey)
            return stored == 0 ? 7 : min(30, max(1, stored))
        }
        set {
            if let newValue {
                defaults.set(false, forKey: disabledKey)
                defaults.set(min(30, max(1, newValue)), forKey: daysKey)
            } else {
                defaults.set(true, forKey: disabledKey)
            }
        }
    }
}

public extension Notification.Name {
    static let savedMediaChanged = Notification.Name("LunaSavedMediaChanged")
}
