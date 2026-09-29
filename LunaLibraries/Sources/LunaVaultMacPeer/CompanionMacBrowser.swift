import Foundation
import Darwin
import LunaVaultBEP

/// On-demand reads only. Never scans recursively, opens a writable descriptor,
/// or adds anything to CompanionIndex. macOS permissions apply to every access.
public struct CompanionMacBrowser: Sendable {
    private let homeURL: URL
    public init(homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) { self.homeURL = homeURL }

    public func respond(to wire: BEPRequest) -> Result<Data, BEPErrorCode> {
        guard wire.folder == VaultMacBrowseProtocol.folder, wire.offset == 0,
              wire.size == 0, wire.hash.isEmpty, !wire.fromTemporary else { return .failure(.invalidFile) }
        let response: VaultMacBrowseResponse
        do { response = try perform(VaultMacBrowseRequest(encodedName: wire.name)) }
        catch { response = VaultMacBrowseResponse(error: error.localizedDescription) }
        guard let data = try? JSONEncoder().encode(response), data.count <= VaultMacBrowseProtocol.maximumResponseSize else {
            return .failure(.generic)
        }
        return .success(data)
    }

    public func perform(_ request: VaultMacBrowseRequest) throws -> VaultMacBrowseResponse {
        if request.operation == .locations {
            let locations = [("Home", homeURL), ("Desktop", homeURL.appendingPathComponent("Desktop")),
                ("Documents", homeURL.appendingPathComponent("Documents")), ("Downloads", homeURL.appendingPathComponent("Downloads")),
                ("Macintosh HD", URL(fileURLWithPath: "/")), ("Volumes", URL(fileURLWithPath: "/Volumes"))]
            return VaultMacBrowseResponse(entries: locations.map { name, url in
                VaultMacBrowseEntry(path: url.path, name: name, isDirectory: true, size: 0, modifiedAt: .distantPast)
            })
        }
        guard request.path.hasPrefix("/"), !request.path.utf8.contains(0), request.path.utf8.count <= 16_384 else {
            throw VaultMacBrowseError("Choose an absolute Mac folder or file path.")
        }
        let url = URL(fileURLWithPath: request.path).standardizedFileURL
        switch request.operation {
        case .locations: return VaultMacBrowseResponse()
        case .list:
            guard request.offset >= 0, request.offset <= Int64(Int.max - VaultMacBrowseProtocol.pageSize) else {
                throw VaultMacBrowseError("Invalid folder page.")
            }
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                    options: request.showHidden ? [] : [.skipsHiddenFiles])
            } catch { throw readableError(error) }
            // Stable page order; the phone sorts each page's rows folders-first.
            let sorted = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let start = min(Int(request.offset), sorted.count)
            let end = min(start + VaultMacBrowseProtocol.pageSize, sorted.count)
            let entries = sorted[start..<end].compactMap { try? entry(at: $0) }
            return VaultMacBrowseResponse(entries: entries, nextOffset: end < sorted.count ? Int64(end) : nil)
        case .stat, .read:
            // O_NONBLOCK prevents a FIFO/device from hanging before fstat can
            // reject it. Symlinks may be followed because the whole Mac is readable.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw accessError() }
            defer { Darwin.close(descriptor) }
            var info = Darwin.stat()
            guard fstat(descriptor, &info) == 0 else { throw accessError() }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw VaultMacBrowseError("Only regular files can be downloaded. Open folders to browse their contents.")
            }
            let version = signature(info)
            if request.operation == .stat { return VaultMacBrowseResponse(entries: [entry(url, info)]) }
            guard request.version == version else { throw VaultMacBrowseError("This file changed on your Mac. Open it again to download the latest copy.") }
            guard request.offset >= 0, request.length > 0, request.length <= VaultMacBrowseProtocol.chunkSize,
                  request.offset <= info.st_size, Int64(request.length) <= info.st_size - request.offset else {
                throw VaultMacBrowseError("Invalid file range.")
            }
            var bytes = Data(count: request.length)
            let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, request.length, off_t(request.offset)) }
            guard count == request.length else { throw VaultMacBrowseError("The Mac couldn’t read the complete file. Try again.") }
            var after = Darwin.stat()
            guard fstat(descriptor, &after) == 0, signature(after) == version else {
                throw VaultMacBrowseError("This file changed during download. Open it again.")
            }
            return VaultMacBrowseResponse(data: bytes)
        }
    }

    private func entry(at url: URL) throws -> VaultMacBrowseEntry {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { throw accessError() }
        guard [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { throw VaultMacBrowseError("Unsupported file type.") }
        return entry(url, info)
    }
    private func entry(_ url: URL, _ info: Darwin.stat) -> VaultMacBrowseEntry {
        VaultMacBrowseEntry(path: url.path, name: url.lastPathComponent, isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            size: Int64(info.st_size), modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
            version: signature(info))
    }
    private func signature(_ info: Darwin.stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    private func accessError() -> VaultMacBrowseError {
        if errno == EACCES || errno == EPERM { return permissionError() }
        return VaultMacBrowseError("This item is unavailable on your Mac. It may have moved, been removed, or its disk may be disconnected.")
    }
    private func readableError(_ error: Error) -> Error {
        let value = error as NSError
        if value.code == NSFileReadNoPermissionError { return permissionError() }
        return VaultMacBrowseError("Couldn’t read this folder on your Mac. Check that it still exists and its disk is connected.")
    }
    private func permissionError() -> VaultMacBrowseError {
        VaultMacBrowseError("macOS hasn’t allowed Luna Vault to read this item. On your Mac, allow access in System Settings → Privacy & Security → Files and Folders or Full Disk Access, then try again.")
    }
}
