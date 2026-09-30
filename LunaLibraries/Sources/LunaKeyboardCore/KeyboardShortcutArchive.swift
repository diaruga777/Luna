import Foundation
import LunaStorage

/// Portable, versioned single-shortcut file. IDs and file paths are never imported.
public struct KeyboardShortcutArchive: Codable {
  public let version: Int
  public let keywords: [String]
  public let text: String
  public let kind: String
  public let suggestWhileTyping: Bool
  public let isCosmetic: Bool
  public let mediaExtension: String?
  public let media: Data?

  public init(shortcut: KeyboardShortcut, store: KeyboardStore) throws {
    version = 1
    keywords = shortcut.keywords
    text = shortcut.text
    kind = shortcut.kind
    suggestWhileTyping = shortcut.suggestWhileTyping
    isCosmetic = shortcut.isCosmetic
    if kind != "text" {
      guard let url = store.fileURL(for: shortcut),
        (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024
      else { throw CocoaError(.fileReadTooLarge) }
      mediaExtension = url.pathExtension
      media = try Data(contentsOf: url)
    } else { mediaExtension = nil; media = nil }
  }
  public static func read(_ url: URL) throws -> Self {
    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 12 * 1024 * 1024
    else { throw CocoaError(.fileReadTooLarge) }
    let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard result.version == 1, ["text", "image", "gif"].contains(result.kind),
      !result.text.isEmpty, result.text.count <= 16000, !result.keywords.isEmpty,
      result.keywords.count <= 100, result.keywords.allSatisfy({ !$0.isEmpty && $0.count <= 256 }),
      (result.media?.count ?? 0) <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
    if result.kind == "text" {
      guard result.media == nil, result.mediaExtension == nil else { throw CocoaError(.fileReadCorruptFile) }
    } else {
      guard result.media != nil, ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(result.mediaExtension ?? "")
      else { throw CocoaError(.fileReadCorruptFile) }
    }
    return result
  }
  public func save(to store: KeyboardStore) throws {
    let entry = KeyboardShortcut(keywords: keywords, text: text, kind: kind,
      suggestWhileTyping: suggestWhileTyping, isCosmetic: isCosmetic)
    var source: URL?
    defer { if let source { try? FileManager.default.removeItem(at: source) } }
    if let media, let ext = mediaExtension {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
      try media.write(to: url, options: .atomic)
      source = url
    }
    try store.save(entry, importing: source)
  }
}
