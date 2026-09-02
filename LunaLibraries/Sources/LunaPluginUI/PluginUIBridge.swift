//
//  PluginUIBridge.swift
//  LunaPluginUI
//

import Foundation
import JavaScriptCore
import LunaPluginKit
import LunaPluginRuntime

/// `luna.ui` — the five things a plugin may ask the person using Luna
/// (`claudedocs/plans/plugin-platform.md` §6.12).
///
/// App only. An extension has a host's presentation to itself and finishes in
/// seconds; a prompt there would either be dismissed unanswered or hold a
/// process the system is about to end. Those calls reject with
/// `unavailable-here`, which is a plugin's cue to fall back rather than fail.
public final class PluginUIBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.ui

    private let processKind: PluginProcessKind
    private let scheduler: PluginCallbackScheduling

    public init(processKind: PluginProcessKind, scheduler: PluginCallbackScheduling) {
        self.processKind = processKind
        self.scheduler = scheduler
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let bridge = self

        let prompt: @convention(block) (JSValue?) -> JSValue? = { argument in
            bridge.answer(in: outerContext) { presenter in
                let options = PluginBridgeValue.dictionary(argument)
                let text = await presenter.prompt(
                    title: PluginBridgeValue.string(options, "title") ?? "",
                    message: PluginBridgeValue.string(options, "message"),
                    placeholder: PluginBridgeValue.string(options, "placeholder"),
                    keyboard: PluginBridgeValue.string(options, "keyboard")
                        .flatMap(PluginPromptKeyboard.init(rawValue:)) ?? .defaultKeyboard,
                    secure: PluginBridgeValue.bool(options, "secure") ?? false,
                    defaultValue: PluginBridgeValue.string(options, "default"))
                return text ?? NSNull()
            }
        }

        let confirm: @convention(block) (JSValue?) -> JSValue? = { argument in
            bridge.answer(in: outerContext) { presenter in
                let options = PluginBridgeValue.dictionary(argument)
                return await presenter.confirm(
                    title: PluginBridgeValue.string(options, "title") ?? "",
                    message: PluginBridgeValue.string(options, "message"),
                    ok: PluginBridgeValue.string(options, "ok"),
                    cancel: PluginBridgeValue.string(options, "cancel"),
                    destructive: PluginBridgeValue.bool(options, "destructive") ?? false)
            }
        }

        let choose: @convention(block) (JSValue?) -> JSValue? = { argument in
            bridge.answer(in: outerContext) { presenter in
                let options = PluginBridgeValue.dictionary(argument)
                let rows = (options["options"] as? [[String: Any]] ?? []).compactMap {
                    row -> PluginUIChoiceOption? in
                    guard let id = row["id"] as? String, let label = row["label"] as? String
                    else { return nil }
                    return PluginUIChoiceOption(
                        id: id, label: label, detail: row["detail"] as? String)
                }
                let chosen = await presenter.choose(
                    title: PluginBridgeValue.string(options, "title") ?? "", options: rows)
                return chosen ?? NSNull()
            }
        }

        let toast: @convention(block) (JSValue?) -> JSValue? = { message in
            bridge.answer(in: outerContext) { presenter in
                await presenter.toast(PluginBridgeValue.optionalString(message) ?? "")
                return NSNull()
            }
        }

        let shareSheet: @convention(block) (JSValue?) -> JSValue? = { items in
            let context = JSContext.current() ?? outerContext
            let resolved = Self.shareItems(items, context: context)
            return bridge.answer(in: outerContext) { presenter in
                await presenter.shareSheet(items: resolved)
                return NSNull()
            }
        }

        let ui = namespace.makeNamespaceObject()
        ui.setObject(prompt, forKeyedSubscript: "prompt" as NSString)
        ui.setObject(confirm, forKeyedSubscript: "confirm" as NSString)
        ui.setObject(choose, forKeyedSubscript: "choose" as NSString)
        ui.setObject(toast, forKeyedSubscript: "toast" as NSString)
        ui.setObject(shareSheet, forKeyedSubscript: "shareSheet" as NSString)
        namespace.install(ui, as: capabilityName.rawValue)
    }

    /// The shape every `luna.ui` call has: a promise, refused outside the app,
    /// otherwise settled with whatever the presenter answered on the main actor.
    private func answer(
        in outerContext: JSContext,
        _ work: @escaping (any PluginUIPresenting) async -> Any
    ) -> JSValue? {
        let context = JSContext.current() ?? outerContext
        let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
        guard processKind == .app else {
            box.fail("luna.ui is available in the app only", code: "unavailable-here")
            return promise
        }
        Task { @MainActor in
            guard let presenter = PluginUIComposition.presenter else {
                box.fail("nothing is on screen to ask", code: "unavailable-here")
                return
            }
            box.fulfill(await work(presenter))
        }
        return promise
    }

    /// The three item shapes §6.12 allows. A `FileHandle` is named by its id,
    /// resolved through the same scratch store `luna.files` reads — never a
    /// bare path, which would let a plugin name any file in the app container.
    /// An id the store no longer holds is dropped rather than shared.
    private static func shareItems(_ value: JSValue?, context: JSContext) -> [PluginShareItem] {
        guard let raw = value?.toArray() else { return [] }
        return raw.compactMap { entry in
            if let text = entry as? String { return .text(text) }
            guard let object = entry as? [String: Any] else { return nil }
            if let urlText = object["url"] as? String, let url = URL(string: urlText) {
                return .url(url)
            }
            if let text = object["text"] as? String { return .text(text) }
            guard let handle = JSValue(object: object, in: context),
                  let descriptor = PluginFilesBridge.descriptor(from: handle),
                  let store = PluginPlatformServices.scratch,
                  let url = store.fileURL(for: descriptor)
            else { return nil }
            return .fileURL(url)
        }
    }
}
