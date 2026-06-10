//
//  BackgroundResourceUploadExtension.swift
//  BackgroundResourceUploadExtension
//
//  The one iOS hook that proactively wakes the app in the background when new photos
//  are added (PhotoKit's resource-upload extension point, iOS 26.1+). We don't
//  upload — we use the wake to scan the newly-added photos for the pocket trigger
//  (a dark/uniform frame) and fire a notification, so a pocket photo taken with the
//  system camera is reacted to within minutes even when Clip isn't open.
//
//  Intentionally lightweight (luminance only, no CLIP/VLM) so it stays well under the
//  extension's tight memory ceiling and never jetsams.
//

import ExtensionFoundation
import Foundation
import Photos

@main
final class BackgroundUploadExtension: PHBackgroundResourceUploadExtension {

    required init() {}

    func process() -> PHBackgroundResourceUploadProcessingResult {
        // process() is synchronous; bridge to the async scan and block this background
        // thread until the bounded batch completes.
        let semaphore = DispatchSemaphore(value: 0)
        let moreWork = LockedBool()
        Task {
            let remaining = await BackgroundPhotoScanRunner().runBatch()
            moreWork.set(remaining)
            semaphore.signal()
        }
        semaphore.wait()
        return moreWork.get() ? .processing : .completed
    }

    func notifyTermination() {}
}

/// Minimal thread-safe boolean to ferry the result out of the bridging `Task`.
private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
    func get() -> Bool { lock.withLock { value } }
}
