//
//  LunaFileReader.swift
//  LunaModels
//

import Foundation

/// Reads a Luna file off disk as text, under the same limits every surface
/// applies. The app opens a security-scoped inbox copy and the share extension
/// a provider's temporary file, so both go through this.
public enum LunaFileReader {

    /// Reads `url` as UTF-8, taking a security scope for as long as the read
    /// lasts. Fails when the file is longer than `LunaFileLimits.maxSourceKB`
    /// or is not UTF-8.
    public static func readText(at url: URL) -> Result<String, LunaFileError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= LunaFileLimits.maxSourceKB * 1024 else {
            return .failure(.fileTooLarge(limitKB: LunaFileLimits.maxSourceKB))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.notText) }
        guard data.count <= LunaFileLimits.maxSourceKB * 1024 else {
            return .failure(.fileTooLarge(limitKB: LunaFileLimits.maxSourceKB))
        }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notText) }
        return .success(text)
    }

    /// Removes a copy the system made for this app in its own inbox. A file the
    /// user opened from Files or another app stays where it is.
    ///
    /// `LSSupportsOpeningDocumentsInPlace` is false, so an Open In hands over a
    /// copy under `Documents/Inbox`, and nothing else ever reads it.
    public static func deleteInboxCopy(
        at url: URL, fileManager: FileManager = .default
    ) -> Bool {
        guard url.isFileURL else { return false }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let inbox = documents?.appendingPathComponent("Inbox")
            .resolvingSymlinksInPath().standardizedFileURL else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(inbox.path + "/") else { return false }
        return (try? fileManager.removeItem(at: url)) != nil
    }
}
