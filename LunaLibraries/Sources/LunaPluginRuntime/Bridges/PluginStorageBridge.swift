//
//  PluginStorageBridge.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit

/// `luna.storage` (§6.5): a plugin's own key/value pairs and its document
/// collections, in the shared App-Group database so every process sees them.
///
/// Every call answers a Promise, because the Safari world serves the same names
/// by relaying to native and a plugin must not have to write two shapes.
public final class PluginStorageBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.storage

    private let store: PluginKVStore
    private let scheduler: PluginCallbackScheduling
    /// Storage work runs off the plugin queue, so a slow write does not hold the
    /// one queue every plugin's JavaScript shares.
    private let workQueue = DispatchQueue(
        label: "com.hsanabria.luna.pluginStorage", qos: .userInitiated)

    public init(store: PluginKVStore = .shared, scheduler: PluginCallbackScheduling) {
        self.store = store
        self.scheduler = scheduler
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let pluginID = namespace.pluginID
        let storage = namespace.makeNamespaceObject()
        let store = self.store
        let scheduler = self.scheduler
        let workQueue = self.workQueue

        let get: @convention(block) (String?) -> JSValue? = { key in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let key, !key.isEmpty else {
                box.fail("luna.storage.get needs a key", code: "bad-argument")
                return promise
            }
            workQueue.async {
                guard let json = store.valueJSON(pluginID: pluginID, key: key) else {
                    // `undefined` is the answer for a key that holds nothing;
                    // `null` is a value a plugin may have stored on purpose.
                    box.fulfill(NSNull())
                    return
                }
                box.fulfill(PluginBridgeValue.jsonValue(json) ?? NSNull())
            }
            return promise
        }

        let set: @convention(block) (String?, JSValue?) -> JSValue? = { key, value in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let key, !key.isEmpty else {
                box.fail("luna.storage.set needs a key", code: "bad-argument")
                return promise
            }
            guard let json = PluginBridgeValue.jsonText(value?.toObject()) else {
                box.fail("luna.storage.set needs a JSON value", code: "bad-argument")
                return promise
            }
            workQueue.async {
                guard store.setValueJSON(json, pluginID: pluginID, key: key, now: Date()) else {
                    box.fail(
                        "the value is larger than the \(PluginKVStore.maxValueBytes / 1024) KB "
                            + "one key may hold", code: "too-large")
                    return
                }
                box.fulfill(NSNull())
            }
            return promise
        }

        let remove: @convention(block) (String?) -> JSValue? = { key in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let key, !key.isEmpty else {
                box.fail("luna.storage.delete needs a key", code: "bad-argument")
                return promise
            }
            workQueue.async {
                store.setValueJSON(nil, pluginID: pluginID, key: key, now: Date())
                box.fulfill(NSNull())
            }
            return promise
        }

        let keys: @convention(block) (JSValue?) -> JSValue? = { prefix in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            let text = PluginBridgeValue.optionalString(prefix)
            workQueue.async {
                box.fulfill(store.keys(pluginID: pluginID, prefix: text))
            }
            return promise
        }

        let collection: @convention(block) (String?) -> JSValue? = { name in
            let context = JSContext.current() ?? outerContext
            guard let name, !name.isEmpty else {
                PluginBridgeValue.raise("luna.storage.collection needs a name", in: context)
                return nil
            }
            return PluginStorageBridge.collectionObject(
                name: name, pluginID: pluginID, store: store, scheduler: scheduler,
                workQueue: workQueue, in: context)
        }

        storage.setObject(get, forKeyedSubscript: "get" as NSString)
        storage.setObject(set, forKeyedSubscript: "set" as NSString)
        storage.setObject(remove, forKeyedSubscript: "delete" as NSString)
        storage.setObject(keys, forKeyedSubscript: "keys" as NSString)
        storage.setObject(collection, forKeyedSubscript: "collection" as NSString)
        namespace.install(storage, as: capabilityName.rawValue)
    }

    /// One collection's handle: `put`, `get`, `delete`, `find`, `count`.
    private static func collectionObject(
        name: String, pluginID: String, store: PluginKVStore,
        scheduler: PluginCallbackScheduling, workQueue: DispatchQueue, in context: JSContext
    ) -> JSValue {
        let handle = JSValue(newObjectIn: context)!

        let put: @convention(block) (String?, JSValue?, JSValue?) -> JSValue? = {
            id, document, index in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let id, !id.isEmpty,
                  let json = PluginBridgeValue.jsonText(document?.toObject())
            else {
                box.fail("collection.put needs an id and a document", code: "bad-argument")
                return promise
            }
            let keys = PluginBridgeValue.dictionary(index)
            let entry = PluginCollectionDocument(
                id: id, json: json,
                k1: PluginBridgeValue.string(keys, "k1"),
                k2: PluginBridgeValue.string(keys, "k2"))
            workQueue.async {
                guard store.putDocument(
                    entry, collection: name, pluginID: pluginID, now: Date())
                else {
                    box.fail("the document is larger than one row may hold", code: "too-large")
                    return
                }
                box.fulfill(NSNull())
            }
            return promise
        }

        let get: @convention(block) (String?) -> JSValue? = { id in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let id else {
                box.fail("collection.get needs an id", code: "bad-argument")
                return promise
            }
            workQueue.async {
                guard let document = store.document(
                    id: id, collection: name, pluginID: pluginID)
                else {
                    box.fulfill(NSNull())
                    return
                }
                box.fulfill(PluginBridgeValue.jsonValue(document.json) ?? NSNull())
            }
            return promise
        }

        let remove: @convention(block) (String?) -> JSValue? = { id in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let id else {
                box.fail("collection.delete needs an id", code: "bad-argument")
                return promise
            }
            workQueue.async {
                store.removeDocument(id: id, collection: name, pluginID: pluginID)
                box.fulfill(NSNull())
            }
            return promise
        }

        let find: @convention(block) (JSValue?, JSValue?) -> JSValue? = { where_, options in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            let keys = PluginBridgeValue.dictionary(where_)
            let opts = PluginBridgeValue.dictionary(options)
            workQueue.async {
                let rows = store.find(
                    collection: name, pluginID: pluginID,
                    k1: PluginBridgeValue.string(keys, "k1"),
                    k2: PluginBridgeValue.string(keys, "k2"),
                    limit: PluginBridgeValue.int(opts, "limit"),
                    offset: PluginBridgeValue.int(opts, "offset") ?? 0)
                box.fulfill(rows.map { row in
                    ["id": row.id, "doc": PluginBridgeValue.jsonValue(row.json) ?? NSNull()]
                        as [String: Any]
                })
            }
            return promise
        }

        let count: @convention(block) (JSValue?) -> JSValue? = { where_ in
            let context = JSContext.current() ?? context
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            let keys = PluginBridgeValue.dictionary(where_)
            workQueue.async {
                box.fulfill(store.count(
                    collection: name, pluginID: pluginID,
                    k1: PluginBridgeValue.string(keys, "k1"),
                    k2: PluginBridgeValue.string(keys, "k2")))
            }
            return promise
        }

        handle.setObject(put, forKeyedSubscript: "put" as NSString)
        handle.setObject(get, forKeyedSubscript: "get" as NSString)
        handle.setObject(remove, forKeyedSubscript: "delete" as NSString)
        handle.setObject(find, forKeyedSubscript: "find" as NSString)
        handle.setObject(count, forKeyedSubscript: "count" as NSString)
        handle.setObject(name, forKeyedSubscript: "name" as NSString)
        return handle
    }
}
