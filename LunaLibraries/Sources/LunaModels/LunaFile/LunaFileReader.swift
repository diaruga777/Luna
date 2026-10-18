//
//  LunaFileReader.swift
//  LunaModels
//

import Foundation
import zlib

/// Reads binary Luna attachments and legacy UTF-8 sources under the same limits
/// in the app, share/action extensions, and manual plugin importer.
public enum LunaFileReader {

    // 89 L U N A CR LF SUB LF, then container version 1. The non-UTF-8 prefix
    // prevents generic text viewers from mistaking a new attachment for source.
    private static let signature = Data([0x89, 0x4c, 0x55, 0x4e, 0x41, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let version: UInt8 = 1
    private static let maxSourceBytes = LunaFileLimits.maxSourceKB * 1024
    /// zlib's worst-case overhead plus the container header, rounded up.
    public static var maxFileBytes: Int { Int(compressBound(uLong(maxSourceBytes))) + signature.count + 1 }

    /// Reads a security-scoped file and returns its decoded source. Existing
    /// text attachments and JavaScript plugin sources remain importable.
    public static func readText(at url: URL) -> Result<String, LunaFileError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else {
            return .failure(.fileTooLarge(limitKB: LunaFileLimits.maxSourceKB))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.notText) }
        return decode(data)
    }

    /// Version 1 is the signature, one version byte, then exactly one RFC 1950
    /// zlib stream of UTF-8 source. Bound both the attachment and inflated source
    /// before parsing; reject corrupt, truncated, or trailing data.
    public static func decode(_ data: Data) -> Result<String, LunaFileError> {
        guard data.count <= maxFileBytes else {
            return .failure(.fileTooLarge(limitKB: LunaFileLimits.maxSourceKB))
        }
        guard data.starts(with: signature) else {
            return sourceText(data)
        }
        guard data.count > signature.count, data[data.index(data.startIndex, offsetBy: signature.count)] == version else {
            return .failure(.invalidContainer)
        }
        let payload = Data(data.dropFirst(signature.count + 1))
        guard !payload.isEmpty else { return .failure(.invalidContainer) }
        // One extra byte distinguishes the exact source limit from an overflow.
        var output = Data(count: maxSourceBytes + 1)
        var outputLength = uLongf(output.count)
        var inputLength = uLong(payload.count)
        let status = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                uncompress2(destination.bindMemory(to: Bytef.self).baseAddress!, &outputLength,
                            source.bindMemory(to: Bytef.self).baseAddress!, &inputLength)
            }
        }
        if outputLength > maxSourceBytes {
            return .failure(.fileTooLarge(limitKB: LunaFileLimits.maxSourceKB))
        }
        guard status == Z_OK, inputLength == payload.count else {
            return .failure(.invalidContainer)
        }
        output.count = Int(outputLength)
        return sourceText(output)
    }

    private static func sourceText(_ data: Data) -> Result<String, LunaFileError> {
        guard data.count <= maxSourceBytes else {
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
