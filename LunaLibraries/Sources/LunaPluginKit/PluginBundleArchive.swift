import Foundation
import LunaAppConfig
import LunaModels

/// Portable ZIP of plugin sources only. Settings, secrets and granted permissions
/// never travel with a bundle. Entries are read in memory, never extracted by path.
public enum PluginBundleArchive {
    public static let fileExtension = "lunabundle"
    public static var typeIdentifier: String { AppConfig.productBundlePrefix + ".plugin-bundle" }
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumPluginBytes = 4 * 1024 * 1024
    public static let maximumPlugins = 128

    public enum ArchiveError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let detail): return "Cannot open plugin bundle: \(detail)" }
        }
    }

    public static func sources(in data: Data) throws -> [String] {
        guard data.count <= maximumBytes, let archive = ZipArchiveReader(data: data),
              archive.paths.count <= 512 else {
            throw ArchiveError.invalid("invalid ZIP file or bundle is too large.")
        }
        var sources: [String] = []
        var paths = Set<String>()
        var identifiers = Set<String>()
        var totalBytes = 0
        for path in archive.paths {
            guard !path.hasPrefix("/"), !path.contains("\\"),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
                  paths.insert(path).inserted else {
                throw ArchiveError.invalid("unsafe or duplicate file path.")
            }
            if path.hasPrefix("__MACOSX/") || URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") { continue }
            guard path.lowercased().hasSuffix(".js") else { continue }
            guard sources.count < maximumPlugins,
                  let bytes = archive.data(at: path, maximumBytes: maximumPluginBytes, requireIntegrity: true),
                  let source = String(data: bytes, encoding: .utf8) else {
                throw ArchiveError.invalid("\(path) is unreadable or exceeds the bundle limits.")
            }
            totalBytes += bytes.count
            guard totalBytes <= maximumBytes else { throw ArchiveError.invalid("expanded bundle is too large.") }
            let manifest = try PluginManifestParser.parse(source: source).get()
            guard identifiers.insert(manifest.id).inserted else {
                throw ArchiveError.invalid("more than one plugin has the ID \(manifest.id).")
            }
            sources.append(source)
        }
        guard !sources.isEmpty else { throw ArchiveError.invalid("no JavaScript plugins found.") }
        return sources
    }

    public static func data(sources: [String]) throws -> Data {
        guard !sources.isEmpty, sources.count <= maximumPlugins else {
            throw ArchiveError.invalid("select between 1 and \(maximumPlugins) plugins.")
        }
        var archive = ZipArchiveWriter()
        var identifiers = Set<String>()
        var totalBytes = 0
        for (index, source) in sources.enumerated() {
            let manifest = try PluginManifestParser.parse(source: source).get()
            let bytes = Data(source.utf8)
            totalBytes += bytes.count
            guard identifiers.insert(manifest.id).inserted, bytes.count <= maximumPluginBytes,
                  totalBytes <= maximumBytes else { throw ArchiveError.invalid("duplicate plugin ID or bundle is too large.") }
            archive.addEntry(path: String(format: "%03d.js", index + 1), data: bytes, compression: .deflate)
        }
        let result = archive.archiveData()
        guard result.count <= maximumBytes else { throw ArchiveError.invalid("bundle is too large.") }
        return result
    }
}
