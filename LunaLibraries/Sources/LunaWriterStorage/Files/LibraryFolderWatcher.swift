import Foundation
import LunaWriterModels

/// One `.md` file as the folder scan found it.
public struct ExternalFileSnapshot: Equatable, Sendable {
    public let relativePath: String
    public let modifiedAt: Date
    public let size: Int

    public init(relativePath: String, modifiedAt: Date, size: Int) {
        self.relativePath = relativePath
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

public protocol LibraryScanHandling: AnyObject {
    func libraryDidScan(_ files: [ExternalFileSnapshot])
}

/// Watches the library folder for edits made outside Luna.
///
/// The kernel event says only "something under here changed", so the watcher
/// answers it with a deep scan. The scan is coalesced: a copy of twenty files
/// into the folder fires many events and must produce one scan, not twenty.
public final class LibraryFolderWatcher {

    /// How long a burst of file-system events is allowed to settle.
    public static let coalescingInterval: TimeInterval = 1

    public let rootDirectory: URL
    /// The reconciler. Weak: the watcher is a component of the stack that owns
    /// them both.
    public weak var handler: LibraryScanHandling?

    private let queue: DispatchQueue
    private let coalescingInterval: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var pending: DispatchWorkItem?

    public init(
        rootDirectory: URL,
        coalescingInterval: TimeInterval = LibraryFolderWatcher.coalescingInterval
    ) {
        self.rootDirectory = rootDirectory
        self.coalescingInterval = coalescingInterval
        self.queue = DispatchQueue(label: "com.hsanabria.luna.writerFolderWatcher")
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard source == nil else { return }
            try? FileManager.default.createDirectory(
                at: rootDirectory, withIntermediateDirectories: true)
            let descriptor = open(rootDirectory.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            self.descriptor = descriptor
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib],
                queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleScan() }
            source.setCancelHandler { [descriptor] in close(descriptor) }
            self.source = source
            source.resume()
        }
    }

    public func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
            descriptor = -1
        }
    }

    /// Scans now and hands the result to the handler on the watcher's queue.
    public func scanNow() {
        let files = LibraryFolderWatcher.scan(rootDirectory)
        handler?.libraryDidScan(files)
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.scanNow()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + coalescingInterval, execute: work)
    }

    /// Every `.md` file under `root`, with the path relative to it. Hidden
    /// files and package contents are skipped: iCloud and Files leave both
    /// behind and neither is a sheet.
    public static func scan(_ root: URL) -> [ExternalFileSnapshot] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let prefix = root.standardizedFileURL.path
        var files: [ExternalFileSnapshot] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == LibraryFileLayout.fileExtension else { continue }
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            var path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            path.removeFirst(prefix.count)
            while path.hasPrefix("/") { path.removeFirst() }
            files.append(ExternalFileSnapshot(
                relativePath: path,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
