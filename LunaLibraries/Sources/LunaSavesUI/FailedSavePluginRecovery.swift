//
//  FailedSavePluginRecovery.swift
//  LunaSavesUI
//

import Foundation
import UIKit

/// Optional central-app route. Standalone surfaces leave it nil, which keeps
/// plugin authoring out of their failed-card UI without coupling this shared
/// card module to the plugin platform.
public enum FailedSavePluginRecovery {
    public static var present: ((UUID, URL, UIViewController) -> Void)?
}
