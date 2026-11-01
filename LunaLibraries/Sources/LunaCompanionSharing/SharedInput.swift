import UIKit
import ImageIO
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
        let types = provider.registeredTypeIdentifiers.filter { UTType($0)?.conforms(to: expected) == true }
        let concrete = types.first { UTType($0)?.preferredFilenameExtension != nil }
        // UIKit's private image representation is a keyed archive, not an
        // encoded image file. Use the typed object for still images; preserve
        // the original file representation whenever GIF is offered.
        if expected == .image, !types.contains(where: { UTType($0)?.conforms(to: .gif) == true }), provider.canLoadObject(ofClass: UIImage.self) {
            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image = object as? UIImage { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)) }
                }
            }
            guard let data = image.pngData() else { throw CocoaError(.fileReadCorruptFile) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Shared image.png")
                try data.write(to: url); return url
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        if let type = concrete ?? types.first {
            let suggestedName = provider.suggestedName
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    do {
                        if let error { throw error }
                        guard let url else { throw CocoaError(.fileNoSuchFile) }
                        continuation.resume(returning: try stage(url, name: suggestedName, type: UTType(type)!))
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
            // Some hosts advertise only public.image and supply an extensionless
            // temporary URL. Detect its encoded format without decoding the bitmap.
            var resolvedType = type
            if type.conforms(to: .image), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let identifier = CGImageSourceGetType(source), let detected = UTType(identifier as String) {
                resolvedType = detected
            }
            if type.conforms(to: .image), CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceGetType($0) }) == nil,
               let image = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIImage.self, from: Data(contentsOf: url)),
               let data = image.pngData() {
                let destination = directory.appendingPathComponent("Shared image.png")
                try data.write(to: destination); return destination
            }
            var filename = ((name ?? url.lastPathComponent) as NSString).lastPathComponent
            if filename.isEmpty || filename == "." || filename == ".." { filename = "Shared file" }
            if UTType(filenameExtension: (filename as NSString).pathExtension)?.conforms(to: resolvedType) != true,
               let ext = resolvedType.preferredFilenameExtension { filename += "." + ext }
            let destination = directory.appendingPathComponent(filename)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try fm.copyItem(at: url, to: destination)
            return destination
        } catch { try? fm.removeItem(at: directory); throw error }
    }
}
