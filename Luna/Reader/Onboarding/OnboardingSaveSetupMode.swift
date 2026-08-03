//
//  OnboardingSaveSetupMode.swift
//  Luna
//

import Darwin
import Foundation

/// Luna has exactly ONE save lesson: the Action Button shortcut. A device that
/// cannot run it has nothing to be taught — there is no share-sheet
/// demonstration to fall back to — so its surfaces omit the save-setup button
/// entirely rather than offering a lesson that ends nowhere.
enum OnboardingSaveSetupMode: Equatable {
    case actionButtonShortcut
    case unavailable

    static var current: Self {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-forceActionButtonSetup") {
            return .actionButtonShortcut
        }
        #endif
        return OnboardingDeviceCapabilities.current.saveSetupMode
    }
}

struct OnboardingDeviceCapabilities: Equatable {
    var operatingSystemMajorVersion: Int
    var modelIdentifier: String
    var isSimulator: Bool

    var hasActionButton: Bool {
        guard !isSimulator else { return false }
        let components = modelIdentifier
            .dropFirst("iPhone".count)
            .split(separator: ",", maxSplits: 1)
        guard modelIdentifier.hasPrefix("iPhone"),
              let family = components.first.flatMap({ Int($0) })
        else { return false }

        // iPhone16,1 and iPhone16,2 are iPhone 15 Pro / Pro Max. Every
        // subsequent iPhone hardware family has an Action Button. Unknown
        // non-iPhone hardware has none.
        return family > 16
            || (family == 16 && ["iPhone16,1", "iPhone16,2"].contains(modelIdentifier))
    }

    var saveSetupMode: OnboardingSaveSetupMode {
        operatingSystemMajorVersion >= 27 && hasActionButton
            ? .actionButtonShortcut
            : .unavailable
    }

    static var current: Self {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return Self(
            operatingSystemMajorVersion:
                ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            modelIdentifier: Self.hardwareModelIdentifier(),
            isSimulator: simulator)
    }

    private static func hardwareModelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0,
              size > 0
        else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0
        else { return "" }
        return String(cString: bytes)
    }
}
