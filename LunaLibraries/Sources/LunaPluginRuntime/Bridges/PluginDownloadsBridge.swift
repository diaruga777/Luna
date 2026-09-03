//
//  PluginDownloadsBridge.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaModels
import LunaPluginKit
import LunaStorage

/// `luna.downloads` (§5, §6.9): a read-only view of the engine's own live media
/// download jobs, so a plugin can show progress without owning any of it.
///
/// Reads `SavesStore` (SQLite in the App Group) directly rather than going
/// through `LiveMediaDownloadManager`, so it needs nothing the share and action
/// extensions don't already have — it installs the same way in every process
/// kind. Not relayed in Safari: `plugin_host.js` has no native message for it.
public final class PluginDownloadsBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.downloads

    private let store: SavesStore
    private let scheduler: PluginCallbackScheduling
    /// Reads run off the plugin queue, so a slow SQLite scan does not hold the
    /// one queue every plugin's JavaScript shares.
    private let workQueue = DispatchQueue(
        label: "com.hsanabria.luna.pluginDownloads", qos: .userInitiated)

    public init(store: SavesStore = .shared, scheduler: PluginCallbackScheduling) {
        self.store = store
        self.scheduler = scheduler
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let downloads = namespace.makeNamespaceObject()
        let store = self.store
        let scheduler = self.scheduler
        let workQueue = self.workQueue
        let pluginID = namespace.pluginID
        let generationID = namespace.target.generationID

        let jobs: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID,
                generationID: generationID)
            workQueue.async {
                guard box.isOperationValid else {
                    box.fail("the plugin generation is no longer active", code: "generation-closed")
                    return
                }
                let jobs = store.mediaDownloadJobs().map { Self.json(for: $0, store: store) }
                box.fulfill(jobs)
            }
            return promise
        }

        let job: @convention(block) (String?) -> JSValue? = { saveId in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID,
                generationID: generationID)
            guard let saveId, let id = UUID(uuidString: saveId) else {
                box.fail("luna.downloads.job needs a save id", code: "bad-argument")
                return promise
            }
            workQueue.async {
                guard box.isOperationValid else {
                    box.fail("the plugin generation is no longer active", code: "generation-closed")
                    return
                }
                guard let item = store.item(withID: id) else {
                    box.fulfill(NSNull())
                    return
                }
                guard let found = Self.newestJob(
                    forSourceURLString: item.urlString, store: store)
                else {
                    box.fulfill(NSNull())
                    return
                }
                box.fulfill(Self.json(for: found, store: store))
            }
            return promise
        }

        downloads.setObject(jobs, forKeyedSubscript: "jobs" as NSString)
        downloads.setObject(job, forKeyedSubscript: "job" as NSString)
        namespace.install(downloads, as: capabilityName.rawValue)
    }

    /// The job the engine would still show for this URL: the one still in
    /// flight if there is one, matching `JobStore.job(forSourceURLString:)`'s
    /// own rule, else the last of whatever terminal rows are left — a job is
    /// removed the moment it finishes or fails, so more than one row surviving
    /// for a URL is already the edge case, not the common path.
    private static func newestJob(
        forSourceURLString urlString: String, store: SavesStore
    ) -> LiveMediaDownloadJob? {
        let jobs = store.mediaDownloadJobs(forSourceURLString: urlString)
        return jobs.first(where: { !$0.isTerminal }) ?? jobs.last
    }

    /// A job's wire shape. `saveId` is looked up from the job's own source URL
    /// rather than carried by the job, so it answers `null` once the save that
    /// made the download is gone.
    private static func json(for job: LiveMediaDownloadJob, store: SavesStore) -> [String: Any] {
        [
            "saveId": store.item(forURLString: job.sourceURLString)?.id.uuidString ?? NSNull(),
            "sourceUrl": job.sourceURLString,
            "title": job.title,
            "phase": job.phase.rawValue,
            "progress": job.progress,
            "receivedBytes": job.receivedByteCount.map(Double.init) ?? NSNull(),
            "expectedBytes": job.expectedByteCount.map(Double.init) ?? NSNull(),
            "failure": job.errorMessage ?? NSNull(),
            "pluginId": job.pluginID ?? NSNull(),
            "quality": job.quality ?? NSNull(),
        ]
    }
}
