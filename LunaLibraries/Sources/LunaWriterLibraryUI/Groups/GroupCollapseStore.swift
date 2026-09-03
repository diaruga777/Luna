import Foundation
import LunaWriterModels

/// Which sidebar groups the user has collapsed, kept across relaunches.
///
/// Local to this tier rather than a `WriterSettings` property so it needs no
/// change to that storage-owned type; folding it in there later is a plain
/// move.
public final class GroupCollapseStore {
    private static let key = "com.hsanabria.luna.writer.collapsedGroupIDs"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var collapsedGroupIDs: Set<GroupID> {
        get {
            let stored = defaults.stringArray(forKey: Self.key) ?? []
            return Set(stored.compactMap(GroupID.init(storageValue:)))
        }
        set {
            defaults.set(newValue.map(\.storageValue), forKey: Self.key)
        }
    }
}
