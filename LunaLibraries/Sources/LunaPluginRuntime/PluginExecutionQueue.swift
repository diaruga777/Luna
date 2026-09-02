//
//  PluginExecutionQueue.swift
//  LunaPluginRuntime
//

import Foundation

/// Runs plugin JavaScript on one dedicated serial queue.
///
/// **A deadline stops the CALLER waiting. It does not stop the JavaScript.**
/// JavaScriptCore's public API has no execution-time limit, watchdog or
/// interrupt of any kind, so a `while (true) {}` plugin cannot be stopped from
/// outside. An abandoned work item keeps running, keeps its thread, and holds
/// the shared `JSVirtualMachine`'s lock, which is why every later call answers
/// `wedged` until it returns. For a real infinite loop that is never — only the
/// process boundary ends it, and only a share or action extension has one. The
/// consent screen says this plainly: capabilities are contained, running code
/// is not.
final class PluginExecutionQueue {

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var abandonedItems = 0

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// True while an abandoned item is still running. It clears by itself if
    /// that item ever returns.
    var isWedged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandonedItems > 0
    }

    /// Runs `work` on the plugin queue without waiting for it.
    ///
    /// A capability bridge whose work finishes elsewhere — a fetch completing on
    /// a URLSession thread — re-enters its plugin's context from here. Entering
    /// from the finishing thread would run plugin JS off this queue and against
    /// the shared virtual machine's lock.
    func enqueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Runs `work` and reports, through `item`, whether it ever returned.
    ///
    /// The caller polls `item` rather than blocking, so the queue stays free for
    /// the bridge callbacks the hook is waiting on.
    func enqueue(item: PluginQueueItem, _ work: @escaping () -> Void) {
        queue.async { [weak self] in
            work()
            guard let self else { return }
            self.lock.lock()
            if item.markReturned() { self.abandonedItems -= 1 }
            self.lock.unlock()
        }
    }

    /// Marks the item's caller as having given up. A body still running holds
    /// the queue, so the runtime reports itself wedged until it returns.
    func abandon(_ item: PluginQueueItem) {
        lock.lock()
        if item.markAbandoned() { abandonedItems += 1 }
        lock.unlock()
    }
}

/// One queued call's state: whether its synchronous body has returned, and
/// whether its caller gave up first.
final class PluginQueueItem {
    private let lock = NSLock()
    private var returned = false
    private var abandoned = false

    init() {}

    var hasReturned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return returned
    }

    /// True when this marked an ABANDONED item as returned, so the queue can
    /// drop its wedge count.
    fileprivate func markReturned() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        returned = true
        return abandoned
    }

    /// True when the item was still running, so the queue counts a new wedge.
    fileprivate func markAbandoned() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !returned, !abandoned else { return false }
        abandoned = true
        return true
    }
}
