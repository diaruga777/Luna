//
//  CoordinatedJSONFile.swift
//  LunaStorage
//

import Foundation

/// The result of an `NSFileCoordinator` accessor block. Coordination can fail,
/// and the work must still happen when it does, so a caller needs to tell "the
/// accessor produced nil" from "the accessor never ran" — a distinction a
/// plain `?? fallback` cannot make when the value itself is optional.
enum CoordinatedAccessorResult<Value> {
    case notRun
    case value(Value)
}

/// One App-Group JSON file, read and mutated safely from every process that
/// shares it.
///
/// The app, its share/action extensions, and its intents all write these
/// sidecar files, and they take turns rather than run together: an extension
/// can record a failure while the app is suspended, and the app's next
/// mutation has to build on what the extension left behind. So a mutation
/// never applies to a snapshot taken earlier — it opens an `NSFileCoordinator`
/// writing coordination, decodes the file inside it, applies the change, and
/// writes the result back. `lock` serializes callers inside this process; the
/// coordination serializes callers across processes.
///
/// Reads decode the file too, but skip the coordination while the file's
/// (modification date, size) still matches the stat the cached value was
/// decoded under. A cross-process writer does not share this cache, so a read
/// re-stats before it trusts the cache.
///
/// `Value` carries its own JSON shape, so one file's date format or key
/// strategy stays that file's business: pass the coders the format needs.
public final class CoordinatedJSONFile<Value: Codable> {

    /// The cheap "has this file changed since we decoded it" proxy. A
    /// same-mtime, same-size write from another process inside the filesystem's
    /// timestamp granularity is the accepted trade-off.
    private struct FileStatToken: Equatable {
        let modificationDate: Date
        let size: Int
    }

    private let resolveURL: () -> URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let onWrite: (URL) -> Void
    private let makeEmpty: () -> Value

    private let lock = NSLock()
    private let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    private let fileManager = FileManager.default

    private var cachedValue: Value?
    private var cacheToken: FileStatToken?

    /// - Parameters:
    ///   - url: resolves the file's location on every access, so a store whose
    ///     directory is created lazily (or renamed under it) stays correct.
    ///     A nil URL means no shared container: the value then lives in memory
    ///     for this process only.
    ///   - onWrite: runs after a successful write, with the URL written. An
    ///     atomic write replaces the file, so anything set on the file itself —
    ///     a backup-eligibility flag — has to be re-applied here.
    ///   - empty: the value a missing or unreadable file stands for.
    public init(url: @escaping () -> URL?,
                encoder: JSONEncoder = JSONEncoder(),
                decoder: JSONDecoder = JSONDecoder(),
                onWrite: @escaping (URL) -> Void = { _ in },
                empty: @escaping () -> Value) {
        self.resolveURL = url
        self.encoder = encoder
        self.decoder = decoder
        self.onWrite = onWrite
        self.makeEmpty = empty
    }

    public convenience init(url: URL?,
                            encoder: JSONEncoder = JSONEncoder(),
                            decoder: JSONDecoder = JSONDecoder(),
                            onWrite: @escaping (URL) -> Void = { _ in },
                            empty: @escaping () -> Value) {
        self.init(url: { url }, encoder: encoder, decoder: decoder,
                  onWrite: onWrite, empty: empty)
    }

    /// The file's current contents, or the empty value when it is missing or
    /// unreadable.
    public func read() -> Value {
        lock.lock(); defer { lock.unlock() }
        return currentValueLocked()
    }

    /// Applies `body` to the file's current contents inside one writing
    /// coordination and writes the result back.
    @discardableResult
    public func mutate<T>(_ body: (inout Value) -> T) -> T {
        mutateIfChanged { value in (result: body(&value), changed: true) }.result
    }

    /// The same transaction, where `body` reports whether it changed anything —
    /// an unchanged value is not written. Reports back whether the file was
    /// written, for callers that only notify on a real change.
    @discardableResult
    public func mutateIfChanged<T>(
        _ body: (inout Value) -> (result: T, changed: Bool)
    ) -> (result: T, didWrite: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let url = resolveURL() else {
            var value = cachedValue ?? makeEmpty()
            let outcome = body(&value)
            if outcome.changed { cachedValue = value; cacheToken = nil }
            return (outcome.result, false)
        }
        var didWrite = false
        var settled: Value?
        func perform(_ fileURL: URL) -> T {
            var value = decode(at: fileURL) ?? makeEmpty()
            let outcome = body(&value)
            if outcome.changed {
                if save(value, to: fileURL) { didWrite = true; settled = value }
            } else {
                settled = value
            }
            return outcome.result
        }
        var accessorResult = CoordinatedAccessorResult<T>.notRun
        var coordinationError: NSError?
        fileCoordinator.coordinate(
            writingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            accessorResult = .value(perform(coordinatedURL))
        }
        let result: T
        switch accessorResult {
        case .value(let value): result = value
        case .notRun: result = perform(url)
        }
        // Only a value the file is now known to hold may be cached; a failed
        // write leaves the old contents there.
        if let settled {
            cachedValue = settled
            cacheToken = statToken(of: url)
        }
        return (result, didWrite)
    }

    // MARK: - Private

    private func currentValueLocked() -> Value {
        guard let url = resolveURL() else { return cachedValue ?? makeEmpty() }
        let token = statToken(of: url)
        if let cachedValue, let token, token == cacheToken { return cachedValue }
        var decoded: Value?
        var ran = false
        var coordinationError: NSError?
        fileCoordinator.coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            ran = true
            decoded = decode(at: coordinatedURL)
        }
        if !ran { decoded = decode(at: url) }
        let value = decoded ?? makeEmpty()
        cachedValue = value
        cacheToken = token
        return value
    }

    private func decode(at url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url),
              let value = try? decoder.decode(Value.self, from: data)
        else { return nil }
        return value
    }

    private func save(_ value: Value, to url: URL) -> Bool {
        guard let data = try? encoder.encode(value),
              (try? data.write(to: url, options: .atomic)) != nil
        else { return false }
        onWrite(url)
        return true
    }

    private func statToken(of url: URL) -> FileStatToken? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return FileStatToken(modificationDate: modificationDate, size: size)
    }
}

extension JSONEncoder {
    /// ISO-8601 dates — the on-disk date format of the sidecar files beside the
    /// saves list (`saveFailures.json`, `rescueLedger.json`).
    static var sidecarISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    /// Reads the ISO-8601 dates `JSONEncoder.sidecarISO8601` writes.
    static var sidecarISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
