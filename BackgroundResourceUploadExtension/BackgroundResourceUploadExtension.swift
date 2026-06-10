//
//  BackgroundResourceUploadExtension.swift
//  BackgroundResourceUploadExtension
//
//  Created by Harry Sanabria on 6/9/26.
//

import ExtensionFoundation
import Foundation
import Photos

/// Background hook woken by PhotoKit when new photos are added. Instead of
/// uploading, we use it as an on-device trigger to run the applet ingest pipeline
/// locally (see `BackgroundIngestRunner`): match new photos against applets, update
/// counts, and notify — all without leaving the device.
@main
final class BackgroundUploadExtension: PHBackgroundResourceUploadExtension {

    private let logger: Logger = Logger()

    required init() {}

    func process() -> PHBackgroundResourceUploadProcessingResult {
        let runner = BackgroundIngestRunner(logger: logger)

        // process() is synchronous; bridge to the async pipeline and block this
        // background thread until the batch completes.
        let semaphore = DispatchSemaphore(value: 0)
        let moreWork = LockedBool()
        Task {
            let remaining = await runner.runBatch()
            moreWork.set(remaining)
            semaphore.signal()
        }
        semaphore.wait()

        return moreWork.get() ? .processing : .completed
    }

    func notifyTermination() {
        logger.info("Background ingest extension terminating")
    }
}

/// Minimal thread-safe boolean to ferry the result out of the bridging `Task`.
private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
    func get() -> Bool { lock.withLock { value } }
}
