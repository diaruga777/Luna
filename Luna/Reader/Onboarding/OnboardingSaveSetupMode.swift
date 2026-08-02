//
//  OnboardingSaveSetupMode.swift
//  Luna
//

import Darwin
import Foundation

enum OnboardingSaveSetupMode: Equatable {
    case actionButtonShortcut
    case shareSheet

    static var current: Self {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-forceActionButtonSetup") {
            return .actionButtonShortcut
        }
        #endif
        OnboardingDeviceCapabilities.current.saveSetupMode
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
        // non-iPhone hardware remains on the share-sheet fallback.
        return family > 16
            || (family == 16 && ["iPhone16,1", "iPhone16,2"].contains(modelIdentifier))
    }

    var saveSetupMode: OnboardingSaveSetupMode {
        operatingSystemMajorVersion >= 27 && hasActionButton
            ? .actionButtonShortcut
            : .shareSheet
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
