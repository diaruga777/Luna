//
//  XteinkTransferSizePolicy.swift
//  LunaSend
//

import Foundation

/// The transport selected for a finalized Xteink EPUB.
///
/// The distinction deliberately happens after `EpubBuilder.Profile.xteink`
/// has omitted images and DEFLATEd text. Routing an earlier, generic-export
/// byte count would send small reader books down the wrong path.
public enum XteinkTransferTransport: String, Sendable, Equatable {
    case bluetoothLowEnergy
    case wifi
}

/// Chooses between the low-energy and Wi-Fi Xteink transports.
///
/// The BLE ceiling is inclusive: a book of exactly 200 KiB is eligible for
/// BLE. Keeping the policy independent of either transport lets the eventual
/// BLE client and Wi-Fi fallback share one deterministic decision.
public struct XteinkTransferSizePolicy: Sendable, Equatable {

    public static let defaultBLEMaximumBytes = 200 * 1024

    public let maximumBLEBytes: Int

    public init(maximumBLEBytes: Int = XteinkTransferSizePolicy.defaultBLEMaximumBytes) {
        self.maximumBLEBytes = max(0, maximumBLEBytes)
    }

    /// Selects a transport from the byte count of the *final Xteink-profile*
    /// EPUB, not from source HTML or a normal EPUB that may contain images.
    public func transport(forFinalXteinkEPUBByteCount byteCount: Int) -> XteinkTransferTransport {
        byteCount <= maximumBLEBytes ? .bluetoothLowEnergy : .wifi
    }

    /// Convenience overload for a finalized Xteink-profile EPUB.
    public func transport(forFinalXteinkEPUB epubData: Data) -> XteinkTransferTransport {
        transport(forFinalXteinkEPUBByteCount: epubData.count)
    }
}
