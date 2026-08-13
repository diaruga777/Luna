//
//  CoordinatedJSONIndex.swift
//  LunaStorage
//

import Foundation

/// The shared `NSLock` + `NSFileCoordinator` "load → mutate → save" wrapper for a
/// JSON index file mutated from multiple processes — the app and its extensions
/// all touch `preloads.json`. An uncoordinated load→save would let the last
/// writer clobber another process's concurrent change: `lock` serializes
/// callers within this process, and `fileCoordinator` serializes callers
/// across processes. `load` and `save` do the caller's own JSON (de)coding, so
/// this function stays index-type-agnostic.
@discardableResult
func coordinatedMutateJSONIndex<Index, T>(
    lock: NSLock, fileCoordinator: NSFileCoordinator, indexURL: URL,
    load: (URL) -> Index, save: (Index, URL) -> Void, body: (inout Index) -> T
) -> T {
    lock.lock(); defer { lock.unlock() }
    func perform(_ url: URL) -> T {
        var index = load(url)
        let result = body(&index)
        save(index, url)
        return result
    }
    // `T` may itself be Optional, so `CoordinatedAccessorResult` rather than a
    // `?? fallback`: a legitimate `nil` value and an accessor that never ran are
    // different answers.
    var coordinatedResult = CoordinatedAccessorResult<T>.notRun
    var coordError: NSError?
    fileCoordinator.coordinate(writingItemAt: indexURL, options: [], error: &coordError) { url in
        coordinatedResult = .value(perform(url))
    }
    switch coordinatedResult {
    case .value(let result):
        return result
    case .notRun:
        return perform(indexURL)
    }
}
