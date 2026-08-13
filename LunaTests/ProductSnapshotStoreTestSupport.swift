//
//  ProductSnapshotStoreTestSupport.swift
//  LunaTests
//

import Foundation
import LunaPriceCompare

extension ProductSnapshotStore {

    /// A store in a throwaway directory, pre-seeded with `snapshots` through
    /// the real write path — so what a test reads back went through the same
    /// index the app writes.
    ///
    /// The caller owns the directory: `removeAfter` hands it back for teardown.
    static func temporary(
        _ snapshots: [ProductSnapshot] = [], directory: inout URL?
    ) -> ProductSnapshotStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductSnapshots-\(UUID().uuidString)")
        directory = url
        let store = ProductSnapshotStore(directoryURL: url)
        // Pruning is measured from the NEWEST fixture day rather than the wall
        // clock, so a suite whose fixtures are dated in the past keeps them all
        // and a suite dated in the future does not evict its own earlier rows.
        let now = snapshots.compactMap { $0.day.startOfDayUTC }.max() ?? Date()
        for snapshot in snapshots { store.record(snapshot, now: now) }
        return store
    }
}
