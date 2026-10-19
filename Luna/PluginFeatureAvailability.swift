import LunaModels
import LunaPluginExport
import LunaPluginKit

/// UI availability follows installed manifests, including disabled plugins.
/// Legacy surfaces keep their native integrations.
enum PluginFeatureAvailability {
    static var hasVideoPlugin: Bool {
        LunaApp.current != .luna
            || PluginPlatformServices.catalog?.listings().contains {
                $0.summary.produces.contains(.media)
            } == true
    }

    static var hasKindlePlugin: Bool {
        isDestinationAvailable(ArticleDestinationID.kindle)
    }

    static func isDestinationAvailable(_ destinationID: String) -> Bool {
        guard LunaApp.current == .luna,
              let pluginID = PluginDestinationLegacyIDs.byPluginID.first(where: {
                  $0.value == destinationID
              })?.key
        else { return true }
        return PluginPlatformServices.catalog?.listing(pluginID: pluginID) != nil
    }
}
