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
///
/// A vnode source reports events for its own directory only, and a sheet's
/// file lives inside a group folder — never directly under the root — so the
/// watcher opens one source per directory, re-walking the tree after every
/// scan to pick up a folder made since the last one.
public final class LibraryFolderWatcher {

    /// How long a burst of file-system events is allowed to settle.
    public static let coalescingInterval: TimeInterval = 1
    /// Posted by name rather than by the typed UIKit constant, so this
    /// Foundation-only tier stays buildable on a platform without UIKit.
    private static let foregroundNotificationName = Notification.Name(
        "UIApplicationWillEnterForegroundNotification")

    public let rootDirectory: URL
    /// The reconciler. Weak: the watcher is a component of the stack that owns
    /// them both.
    public weak var handler: LibraryScanHandling?

    private let queue: DispatchQueue
    private let coalescingInterval: TimeInterval
    private var sources: [URL: DirectoryWatch] = [:]
    private var pending: DispatchWorkItem?
    private var foregroundObserver: NSObjectProtocol?

    private struct DirectoryWatch {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    public init(
        rootDirectory: URL,
        coalescingInterval: TimeInterval = LibraryFolderWatcher.coalescingInterval
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.coalescingInterval = coalescingInterval
        self.queue = DispatchQueue(label: "com.hsanabria.luna.writerFolderWatcher")
    }

    deinit {
        // No `queue.sync` here: the last strong reference can itself be
        // released from a block running on `queue`, and syncing onto
        // ourselves from inside that block would deadlock. Cancelling the
        // sources directly is safe from any thread once no one else can call
        // into this instance any more.
        for watch in sources.values { watch.source.cancel() }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    public func start() {
        queue.sync {
            guard sources.isEmpty else { return }
            try? FileManager.default.createDirectory(
                at: rootDirectory, withIntermediateDirectories: true)
            watchDirectories(in: LibraryFolderWatcher.directories(under: rootDirectory))
        }
        observeForeground()
    }

    /// The owner's job, never `deinit`'s: see the note there.
    public func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            for watch in sources.values { watch.source.cancel() }
            sources.removeAll()
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    /// Scans now, on the watcher's queue, and hands the result to the handler.
    public func scanNow() {
        queue.async { [weak self] in self?.performScan() }
    }

    /// The floor under the coalesced watch: a dispatch source only fires
    /// while the process runs, so a directory written to while the app was
    /// suspended raises no event to coalesce. Called on returning to the
    /// foreground.
    public func scanOnForeground() { scanNow() }

    private func performScan() {
        watchDirectories(in: LibraryFolderWatcher.directories(under: rootDirectory))
        let files = LibraryFolderWatcher.scan(rootDirectory)
        handler?.libraryDidScan(files)
    }

    private func observeForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: Self.foregroundNotificationName, object: nil, queue: nil
        ) { [weak self] _ in self?.scanOnForeground() }
    }

    /// Adds a source for every directory not already watched and cancels one
    /// for any that is no longer there. Must run on `queue`.
    private func watchDirectories(in directories: [URL]) {
        let current = Set(directories)
        for (url, watch) in sources where !current.contains(url) {
            watch.source.cancel()
            sources[url] = nil
        }
        for url in current where sources[url] == nil {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib],
                queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if url == self.rootDirectory, !source.data.isDisjoint(with: [.rename, .delete]) {
                    self.restartAfterRootChange()
                }
                self.scheduleScan()
            }
            source.setCancelHandler { [descriptor] in close(descriptor) }
            sources[url] = DirectoryWatch(descriptor: descriptor, source: source)
            source.resume()
        }
    }

    /// A dispatch source over a renamed or deleted root stays open but stops
    /// meaning anything: the vnode it watches no longer names the library
    /// folder. Every watch is torn down and reopened against a freshly
    /// (re)created root. Must run on `queue`.
    private func restartAfterRootChange() {
        for watch in sources.values { watch.source.cancel() }
        sources.removeAll()
        try? FileManager.default.createDirectory(
            at: rootDirectory, withIntermediateDirectories: true)
        watchDirectories(in: LibraryFolderWatcher.directories(under: rootDirectory))
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.performScan()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + coalescingInterval, execute: work)
    }

    /// Every directory under `root`, root included, skipping hidden ones —
    /// `.Trash` among them, so trash churn schedules no scan of its own.
    private static func directories(under root: URL) -> [URL] {
        var result = [root.standardizedFileURL]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return result }
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { result.append(url.standardizedFileURL) }
        }
        return result
    }

    /// Every `.md` file under `root`, with the path relative to it. Hidden
    /// files and package contents are skipped: iCloud and Files leave both
    /// behind and neither is a sheet. Paths are folded to precomposed Unicode
    /// so a decomposed name on disk still matches the composed form a row
    /// stores.
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
                relativePath: path.precomposedStringWithCanonicalMapping,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
