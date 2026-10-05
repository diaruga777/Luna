//
//  PluginBrowserBridge.swift
//  LunaPluginUI
//

import Foundation
import JavaScriptCore
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaPluginRuntime
import LunaStorage

/// Presents a plugin's browser step and answers what it produced.
///
/// A witness rather than the modal itself: the bridge runs on the plugin queue
/// and must not know how this app puts a view controller on screen.
@MainActor
public protocol PluginBrowserPresenting: AnyObject {
    func presentBrowserStep(
        _ request: PluginBrowserRequest, pluginID: String) async -> PluginBrowserResult?
}

/// `luna.browser.open(request)` — the one way a plugin gets a real browser
/// (`claudedocs/plans/plugin-platform.md` §6.10, §8).
///
/// What it does depends on the process. A share or action extension has no
/// business showing a page and no time to finish one, so the request is stored
/// against the save and the call rejects with `browser-deferred`; the plugin
/// lets that propagate, the walk locks the save, and the app finishes it. In the
/// app the modal is presented and awaited — unless the save already holds the
/// answer to this very request, which is the resume: the stored result is
/// handed back without showing anything.
public final class PluginBrowserBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.browser

    private let processKind: PluginProcessKind
    private let scheduler: PluginCallbackScheduling
    private let requests: PluginBrowserRequestStore
    private let presenter: (any PluginBrowserPresenting)?
    private let diagnostics: PluginDiagnosticsRecording

    /// - Parameter presenter: nil outside the app, where nothing can be shown.
    public init(
        processKind: PluginProcessKind,
        scheduler: PluginCallbackScheduling,
        requests: PluginBrowserRequestStore = .shared,
        presenter: (any PluginBrowserPresenting)? = nil,
        diagnostics: PluginDiagnosticsRecording = PluginDiagnostics.shared
    ) {
        self.processKind = processKind
        self.scheduler = scheduler
        self.requests = requests
        self.presenter = presenter
        self.diagnostics = diagnostics
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let pluginID = namespace.pluginID
        let bridge = self

        let open: @convention(block) (JSValue?) -> JSValue? = { argument in
            let context = JSContext.current() ?? outerContext
            guard let request = PluginBrowserRequest(
                jsObject: PluginBridgeValue.dictionary(argument))
            else {
                PluginBridgeValue.raise(
                    "luna.browser.open needs a url and a detect script: "
                        + "luna.browser.open({ url, detect })", in: context)
                return nil
            }
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: bridge.scheduler, pluginID: pluginID)
            // A plugin running several saves at once names the one it means.
            let named = PluginBridgeValue.string(
                PluginBridgeValue.dictionary(argument), "saveId").flatMap(UUID.init(uuidString:))
            bridge.open(request, pluginID: pluginID, saveID: named, box: box)
            return promise
        }

        let browser = namespace.makeNamespaceObject()
        browser.setObject(open, forKeyedSubscript: "open" as NSString)
        namespace.install(browser, as: capabilityName.rawValue)
    }

    // MARK: - The three answers

    private func open(
        _ request: PluginBrowserRequest, pluginID: String, saveID named: UUID?,
        box: PluginPromiseBox
    ) {
        // A browser step belongs to a save: it is stored against one, and the
        // resume reads it back by id. A hook called outside a save walk — a
        // refresh, a re-resolution — has nowhere to park one.
        let inFlight = PluginIngestScope.saveIDs(pluginID: pluginID)
        let saveID: UUID
        if let named, inFlight.contains(named) {
            saveID = named
        } else if inFlight.count == 1 {
            saveID = inFlight[0]
        } else if inFlight.isEmpty {
            box.fail(
                "luna.browser.open is only available while a save is being ingested",
                code: "unavailable-here")
            return
        } else {
            box.fail(
                "this plugin is ingesting \(inFlight.count) saves at once; pass saveId to say "
                    + "which one the browser step belongs to",
                code: "bad-argument")
            return
        }
        switch processKind {
        case .share, .action:
            self.defer_(request, pluginID: pluginID, saveID: saveID, box: box)
        case .app:
            present(request, pluginID: pluginID, saveID: saveID, box: box)
        }
    }

    private func defer_(
        _ request: PluginBrowserRequest, pluginID: String, saveID: UUID, box: PluginPromiseBox
    ) {
        guard let json = request.jsonText,
              LunaPluginIngest.PluginBrowserDeferral.witness?.defer_(
                  request: json, pluginID: pluginID, saveID: saveID) == true
        else {
            box.fail(
                "the browser request could not be stored, so the save cannot be finished later",
                code: "bridge-failed")
            return
        }
        diagnostics.record(
            "browser deferred \(request.url.absoluteString) for save \(saveID.uuidString.prefix(8))",
            pluginID: pluginID)
        box.fail(
            "this process cannot show a browser; the save is locked until Luna finishes it",
            code: LunaPluginRuntime.PluginBrowserDeferral.code)
    }

    private func present(
        _ request: PluginBrowserRequest, pluginID: String, saveID: UUID, box: PluginPromiseBox
    ) {
        if let stored = storedAnswer(to: request, saveID: saveID) {
            diagnostics.record(
                "browser resumed \(request.url.absoluteString) from the stored result",
                pluginID: pluginID)
            box.fulfill(stored.jsObject)
            return
        }
        guard let presenter else {
            box.fail(
                "no browser can be shown from here", code: "unavailable-here")
            return
        }
        diagnostics.record(
            "browser opening \(request.url.absoluteString)", pluginID: pluginID)
        // The store row is dropped here rather than kept: this run is showing
        // the modal, so a stale request for the same save would only mislead a
        // later launch into offering an unlock for a step already taken.
        requests.clear(saveID: saveID)
        Task { @MainActor in
            guard box.isOperationValid else { return }
            // Awaiting a person is useful work, bounded by the browser request's
            // own deadline. Keep both ingestion idle clocks alive during it.
            let deadline = Date().addingTimeInterval(request.timeout)
            let heartbeat = Task {
                while !Task.isCancelled && box.isOperationValid && Date() < deadline {
                    box.noteActivity()
                    do { try await Task.sleep(nanoseconds: 250_000_000) }
                    catch { return }
                }
            }
            defer { heartbeat.cancel() }
            let result = await presenter.presentBrowserStep(request, pluginID: pluginID)
            guard let result else {
                box.fail("the browser step was cancelled", code: "cancelled")
                return
            }
            box.fulfill(result.jsObject)
        }
    }

    /// The answer a previous browser step left for this exact page, taken once.
    /// A stored answer to a DIFFERENT page is left alone — the plugin has moved
    /// on and the modal has to run again.
    private func storedAnswer(
        to request: PluginBrowserRequest, saveID: UUID
    ) -> PluginBrowserResult? {
        guard let record = requests.record(for: saveID), record.resultJSON != nil,
              let stored = PluginBrowserRequest(json: record.requestJSON),
              stored.addressesSamePage(as: request),
              let json = requests.takeResult(saveID: saveID)
        else { return nil }
        return PluginBrowserResult(json: json)
    }
}
