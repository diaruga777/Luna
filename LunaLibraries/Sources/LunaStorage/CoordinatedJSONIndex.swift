//
//  CoordinatedJSONIndex.swift
//  LunaStorage
//

import Foundation

/// The shared `NSLock` + `NSFileCoordinator` "load → mutate → save" wrapper for a
/// JSON index file mutated from multiple processes (the app and its extensions all
/// touch `imageRefs.json`/`preloads.json`): an uncoordinated load→save would let the
/// last writer clobber another process's concurrent change. `lock` serializes
/// callers within this process; `fileCoordinator` serializes across processes.
/// `load`/`save` do the caller's own JSON (de)coding, so this stays index-type-agnostic.
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
    var coordResult: T?
    var coordError: NSError?
    fileCoordinator.coordinate(writingItemAt: indexURL, options: [], error: &coordError) { url in
        coordResult = perform(url)
    }
    return coordResult ?? perform(indexURL)
}
