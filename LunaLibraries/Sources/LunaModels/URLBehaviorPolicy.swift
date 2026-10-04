import Foundation

/// Core URL semantics belong to installed JavaScript plugins. This remains true
/// with an empty catalog, before runtime installation, and after plugin removal.
/// Sibling apps retain their native feature implementations.
public enum URLBehaviorPolicy {
    public static var pluginsOnly: Bool = LunaApp.current == .luna
}
