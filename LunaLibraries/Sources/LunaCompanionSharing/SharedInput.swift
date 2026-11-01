import UIKit
import UniformTypeIdentifiers

public enum SharedInput {
    public static func providers(in context: NSExtensionContext?) -> [NSItemProvider] {
        (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    }
    public static func text(in context: NSExtensionContext?) async throws -> String {
        var parts: [String] = []
        for item in context?.inputItems as? [NSExtensionItem] ?? [] {
            let providers = item.attachments ?? []
            if providers.isEmpty, let text = item.attributedContentText?.string { parts.append(text) }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try await Self.item(provider, type: UTType.url.identifier) as? URL, !url.isFileURL {
                    parts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let value = try await Self.item(provider, type: UTType.plainText.identifier)
                    if let text = value as? String { parts.append(text) }
                    else if let text = value as? NSAttributedString { parts.append(text.string) }
                    else if let data = value as? Data, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) { parts.append(text) }
                    else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                } else {
                    let url = try await file(provider, conformingTo: .text)
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    let data = try Data(contentsOf: url)
                    let type = UTType(filenameExtension: url.pathExtension)
                    if type?.conforms(to: .rtf) == true || type?.conforms(to: .html) == true {
                        let documentType: NSAttributedString.DocumentType = type?.conforms(to: .rtf) == true ? .rtf : .html
                        parts.append(try NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil).string)
                    } else if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) { parts.append(text) }
                    else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                }
            }
        }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return text
    }
    public static func item(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
    }
    /// Copy inside the provider callback: its URL expires as soon as it returns.
    public static func file(_ provider: NSItemProvider, conformingTo expected: UTType) async throws -> URL {
        if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: expected) == true }) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    do {
                        if let error { throw error }
                        guard let url else { throw CocoaError(.fileNoSuchFile) }
                        continuation.resume(returning: try stage(url, name: provider.suggestedName, type: UTType(type)!))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try await Self.item(provider, type: UTType.fileURL.identifier) as? URL,
           url.isFileURL, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: expected) {
            return try stage(url, name: nil, type: type)
        }
        throw CocoaError(.fileReadUnsupportedScheme)
    }
    private static func stage(_ url: URL, name: String?, type: UTType) throws -> URL {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var filename = ((name ?? url.lastPathComponent) as NSString).lastPathComponent
            if filename.isEmpty || filename == "." || filename == ".." { filename = "Shared file" }
            if UTType(filenameExtension: (filename as NSString).pathExtension)?.conforms(to: type) != true,
               let ext = type.preferredFilenameExtension { filename += "." + ext }
            let destination = directory.appendingPathComponent(filename)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try fm.copyItem(at: url, to: destination)
            return destination
        } catch { try? fm.removeItem(at: directory); throw error }
    }
}
