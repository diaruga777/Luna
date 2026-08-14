//
//  SpotlightIndexState.swift
//  LunaStorage
//

import Foundation

/// One app surface's durable view of its bundle-specific Spotlight index.
///
/// `legacyIndexedIDs` is populated only until this surface completes its first
/// schema-10 sweep. Those ids came from schema 9's shared table and may have
/// belonged to either article app, so BOTH apps must reconcile them once.
public struct SpotlightIndexState: Equatable, Sendable {
    public let indexedIDs: Set<String>
    public let legacyIndexedIDs: Set<String>
    public let needsLegacyReconciliation: Bool

    public init(
        indexedIDs: Set<String>, legacyIndexedIDs: Set<String>,
        needsLegacyReconciliation: Bool
    ) {
        self.indexedIDs = indexedIDs
        self.legacyIndexedIDs = legacyIndexedIDs
        self.needsLegacyReconciliation = needsLegacyReconciliation
    }
}
