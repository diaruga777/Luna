//
//  PluginFilesBridge.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit

/// `luna.files` (§6.7): a per-generation scratch directory under the App Group.
///
/// A handle is a descriptor, never a path: a plugin can hand one back to Luna
/// (an export result, a multipart part) but cannot name a file it did not
/// write. One generation is open while anything of the plugin is in flight, and
/// its directory is reaped when the last of those calls ends.
public final class PluginFilesBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.files

    /// The largest file a plugin may write. It matches the fetch ceiling, so a
    /// response saved with `as: "file"` cannot be refused by the writer that
    /// just accepted it.
    public static let maxFileBytes = PluginFileLimits.maxBytes

    private let scratch: PluginScratchStore
    private let scheduler: PluginCallbackScheduling
    private let workQueue = DispatchQueue(
        label: "com.hsanabria.luna.pluginFiles", qos: .userInitiated)

    public init(scratch: PluginScratchStore, scheduler: PluginCallbackScheduling) {
        self.scratch = scratch
        self.scheduler = scheduler
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let files = namespace.makeNamespaceObject()
        let scratch = self.scratch
        let scheduler = self.scheduler
        let workQueue = self.workQueue
        let pluginID = namespace.pluginID
        let scratchGeneration = namespace.target.scratchGeneration

        let write: @convention(block) (String?, JSValue?, JSValue?) -> JSValue? = {
            name, value, mime in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            guard let name, !name.isEmpty,
                  let data = PluginBridgeValue.data(from: value?.toObject())
            else {
                box.fail(
                    "luna.files.write needs a name and text or { base64 }", code: "bad-argument")
                return promise
            }
            guard data.count <= Self.maxFileBytes else {
                box.fail(
                    "a plugin file may be at most \(Self.maxFileBytes / (1024 * 1024)) MB",
                    code: "too-large")
                return promise
            }
            let generation = scratchGeneration()
            let mimeText = PluginBridgeValue.optionalString(mime)
            workQueue.async {
                do {
                    let descriptor = try scratch.writeFile(
                        data, suggestedName: name, mime: mimeText, pluginID: pluginID,
                        generation: generation)
                    box.fulfill(Self.jsObject(descriptor))
                } catch {
                    box.fail(error.localizedDescription, code: "write-failed")
                }
            }
            return promise
        }

        let read: @convention(block) (JSValue?, JSValue?) -> JSValue? = { handle, form in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            guard let descriptor = Self.descriptor(from: handle) else {
                box.fail("luna.files.read needs a file handle", code: "bad-argument")
                return promise
            }
            let wantsBase64 = PluginBridgeValue.optionalString(form) == "base64"
            workQueue.async {
                guard let url = scratch.fileURL(for: descriptor),
                      let data = try? Data(contentsOf: url)
                else {
                    box.fail("that file is gone", code: "not-found")
                    return
                }
                if wantsBase64 {
                    box.fulfill(data.base64EncodedString())
                    return
                }
                // Decoding invalid UTF-8 would answer a plausible string of
                // U+FFFD, so a plugin reading a downloaded MP4 or EPUB without
                // "base64" would get silently mangled bytes.
                guard let text = String(data: data, encoding: .utf8) else {
                    box.fail(
                        "that file is not UTF-8 text; read it with \"base64\"",
                        code: "not-text")
                    return
                }
                box.fulfill(text)
            }
            return promise
        }

        let size: @convention(block) (JSValue?) -> JSValue? = { handle in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            guard let descriptor = Self.descriptor(from: handle) else {
                box.fail("luna.files.size needs a file handle", code: "bad-argument")
                return promise
            }
            box.fulfill(descriptor.size)
            return promise
        }

        files.setObject(write, forKeyedSubscript: "write" as NSString)
        files.setObject(read, forKeyedSubscript: "read" as NSString)
        files.setObject(size, forKeyedSubscript: "size" as NSString)
        namespace.install(files, as: capabilityName.rawValue)
    }

    /// The handle shape a plugin sees.
    public static func jsObject(_ descriptor: PluginFileDescriptor) -> [String: Any] {
        [
            "id": descriptor.id,
            "name": descriptor.name,
            "size": descriptor.size,
            "mime": descriptor.mime ?? NSNull(),
        ]
    }

    /// Reads a handle a plugin passed back. Only `id` is trusted: the rest is
    /// display, and a plugin editing them changes nothing about which file it
    /// names.
    public static func descriptor(from value: JSValue?) -> PluginFileDescriptor? {
        let object = PluginBridgeValue.dictionary(value)
        guard let id = PluginBridgeValue.string(object, "id") else { return nil }
        return PluginFileDescriptor(
            id: id,
            name: PluginBridgeValue.string(object, "name") ?? "file",
            size: PluginBridgeValue.int(object, "size") ?? 0,
            mime: PluginBridgeValue.string(object, "mime"))
    }
}
