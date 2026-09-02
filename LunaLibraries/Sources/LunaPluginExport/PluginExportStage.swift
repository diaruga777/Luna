//
//  PluginExportStage.swift
//  LunaPluginExport
//

import Foundation
import LunaModels
import LunaPluginKit
import LunaSend
import LunaStorage
import UIKit

/// Presents what an export answered. The app installs the UIKit one; a test
/// installs a recorder and asserts on what was handed over.
@MainActor
public protocol PluginExportSharePresenting: AnyObject {
    /// Hands `items` to the system share sheet, anchored on `sourceView` when
    /// one is still on screen.
    ///
    /// `completion` runs once the sheet is gone, whether it shared or was
    /// cancelled, and runs immediately when nothing can be presented. The stage
    /// deletes the shared file's directory there: the sheet reads the file
    /// after the hook that made it has settled, so nothing else knows when it
    /// stops being needed.
    func presentExportShare(
        items: [Any], from presenter: UIViewController?, sourceView: UIView?,
        completion: @escaping () -> Void)
}

/// What one export run produced.
public enum PluginExportOutcome: Equatable {
    /// The hook answered `null`: it did the work itself and nothing is shown.
    case handled
    /// A file, text or URL result reached the share sheet.
    case presented
    /// A destination's own bookkeeping answer.
    case status(PluginExportResult.Status, message: String?, hard: Bool)
    /// The run did not reach a result. `hard` means retrying cannot help.
    case failed(message: String, hard: Bool)
}

/// Runs one `export` hook end to end (`claudedocs/plans/plugin-platform.md`
/// §9.2): build the input off the main thread, call the hook, sink the result.
///
/// The stage is the ONE place a plugin's export runs, whether the run came from
/// a share row or from the send coordinator delivering a queued send. Its lines
/// go to the `plugin` diagnostics category, so a share that produced nothing is
/// answerable from the Diagnostics screen.
@MainActor
public final class PluginExportStage {

    public static let shared = PluginExportStage()

    /// The budget one export gets. Generous, because a destination plugin may
    /// be waiting on a mail server.
    public static let timeout: TimeInterval = 120

    /// The diagnostics category every export line lands in.
    static let diagnosticsCategory = "plugin"

    /// Presents share results. Installed by `PluginExportComposition`; a nil
    /// presenter means a file result is built and then dropped, which is what
    /// an export run in the background does.
    public var presenter: (any PluginExportSharePresenting)?

    private let invoker: (any PluginHookInvoking)?
    private let producer: PluginExportInputProducer
    private let scratch: PluginScratchStore?

    /// The shipped stage reads the installed platform. A test hands over its
    /// own invoker, producer and scratch store.
    public init(
        invoker: (any PluginHookInvoking)? = nil,
        producer: PluginExportInputProducer? = nil,
        scratch: PluginScratchStore? = nil,
        presenter: (any PluginExportSharePresenting)? = nil
    ) {
        self.invoker = invoker
        self.producer = producer ?? PluginExportInputProducer()
        self.scratch = scratch
        self.presenter = presenter
    }

    private var activeInvoker: (any PluginHookInvoking)? {
        invoker ?? PluginPlatformServices.invoker
    }

    private var activeScratch: PluginScratchStore? {
        scratch ?? PluginPlatformServices.scratch
    }

    /// The export declaration of a loaded plugin, or nil when it is gone,
    /// disabled, or exports nothing.
    public func declaration(pluginID: String) -> PluginExportSummary? {
        activeInvoker?.loadedPlugins.first { $0.id == pluginID }?.export
    }

    @discardableResult
    public func run(
        pluginID: String, saveID: UUID, from presenter: UIViewController? = nil,
        sourceView: UIView? = nil, auto: Bool = false, queuedRemaining: Int? = nil
    ) async -> PluginExportOutcome {
        guard let invoker = activeInvoker, let export = declaration(pluginID: pluginID) else {
            return record(
                .failed(message: "no loaded plugin exports for \(pluginID)", hard: true),
                pluginID: pluginID)
        }
        guard let format = PluginExportInputFormat(rawValue: export.input) else {
            return record(
                .failed(message: "\(pluginID) declares an input Luna cannot build", hard: true),
                pluginID: pluginID)
        }
        let scratch = activeScratch
        // The stage holds the plugin's scratch generation open across the input
        // file, the hook and the sink. The hook's own call joins the same
        // generation, so the input handle it was given still resolves while the
        // result is being shared.
        let generation = scratch?.openScratchGeneration(pluginID: pluginID)
            ?? PluginScratchStore.idleGeneration
        defer { scratch?.closeScratchGeneration(pluginID: pluginID) }
        let input: PluginExportInput
        do {
            input = try await self.producer.makeInput(
                saveID: saveID, format: format, options: export, auto: auto,
                queuedRemaining: queuedRemaining, scratch: scratch,
                pluginID: pluginID, generation: generation)
        } catch {
            return record(
                .failed(message: "\(pluginID) export input: \(error)", hard: isHard(error)),
                pluginID: pluginID)
        }

        let answer = await invoker.invoke(
            .export, pluginID: pluginID, argument: input, timeout: Self.timeout,
            decode: PluginExportResult.self)
        switch answer {
        case .failure(let failure):
            return record(
                .failed(
                    message: Self.message(for: failure), hard: Self.isTerminal(failure)),
                pluginID: pluginID)
        case .success(let result):
            return sink(
                result, pluginID: pluginID, scratch: scratch,
                from: presenter, sourceView: sourceView)
        }
    }

    // MARK: - Sink

    private func sink(
        _ result: PluginExportResult, pluginID: String,
        scratch: PluginScratchStore?, from presenter: UIViewController?, sourceView: UIView?
    ) -> PluginExportOutcome {
        switch result {
        case .handled:
            return record(.handled, pluginID: pluginID)
        case .status(let status, let message, let hard):
            return record(.status(status, message: message, hard: hard), pluginID: pluginID)
        case .url(let text):
            guard let url = URL(string: text) else {
                return record(
                    .failed(message: "\(pluginID) answered an unusable url", hard: true),
                    pluginID: pluginID)
            }
            present([url], directory: nil, from: presenter, sourceView: sourceView)
            return record(.presented, pluginID: pluginID)
        case .text(let text, let name, let mime):
            guard let shared = Self.writeTemporaryFile(
                Data(text.utf8), name: name ?? Self.temporaryName(mime: mime))
            else {
                return record(
                    .failed(message: "\(pluginID) text result could not be written", hard: false),
                    pluginID: pluginID)
            }
            present(
                [shared.file], directory: shared.directory, from: presenter,
                sourceView: sourceView)
            return record(.presented, pluginID: pluginID)
        case .file(let handle, let name, _):
            guard let scratch, let source = scratch.fileURL(for: handle.descriptor) else {
                return record(
                    .failed(message: "\(pluginID) named a file Luna no longer holds", hard: false),
                    pluginID: pluginID)
            }
            // The share sheet reads the file after this stage has let go of the
            // plugin's scratch generation, so the bytes are handed on into a
            // directory of the share's own.
            guard let shared = Self.linkTemporaryFile(
                at: source, name: name ?? handle.name)
            else {
                return record(
                    .failed(message: "\(pluginID) file result could not be shared", hard: false),
                    pluginID: pluginID)
            }
            present(
                [shared.file], directory: shared.directory, from: presenter,
                sourceView: sourceView)
            return record(.presented, pluginID: pluginID)
        }
    }

    /// Presents `items` and removes `directory` once the sheet is gone.
    private func present(
        _ items: [Any], directory: URL?, from presenter: UIViewController?, sourceView: UIView?
    ) {
        guard let sharePresenter = self.presenter else {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            return
        }
        sharePresenter.presentExportShare(
            items: items, from: presenter, sourceView: sourceView
        ) {
            guard let directory else { return }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Failure reading

    private func isHard(_ error: Error) -> Bool {
        guard let error = error as? PluginExportInputError else { return false }
        switch error {
        case .noSave, .noContent, .formatUnavailable:
            // Nothing about the save will change on a retry.
            return true
        case .noScratchStore, .writeFailed:
            return false
        }
    }

    /// A hook that threw is terminal only when it said so. The runtime drops a
    /// `LunaError`'s `details`, so the signal a plugin has is the error CODE:
    /// `throw new luna.LunaError("hard", "…")`.
    nonisolated public static func isTerminal(_ failure: PluginInvocationFailure) -> Bool {
        switch failure {
        case .notLoaded, .missingHook, .malformedResult, .browserDeferred:
            return true
        case .exception(let message, _):
            return message.hasPrefix("hard:")
        case .timedOut, .wedged, .runtime:
            return false
        }
    }

    nonisolated static func message(for failure: PluginInvocationFailure) -> String {
        switch failure {
        case .notLoaded: return "the plugin is not loaded"
        case .missingHook: return "the plugin registered no export hook"
        case .timedOut: return "the export hook ran out of time"
        case .wedged: return "an earlier plugin call still holds the runtime"
        case .exception(let message, _): return message
        case .malformedResult(let detail): return detail
        case .browserDeferred: return "an export cannot open a browser step"
        case .runtime(let detail): return detail
        }
    }

    @discardableResult
    private func record(
        _ outcome: PluginExportOutcome, pluginID: String
    ) -> PluginExportOutcome {
        SharedDiagnosticLog.record(
            "export \(pluginID): \(Self.line(for: outcome))",
            category: Self.diagnosticsCategory)
        return outcome
    }

    static func line(for outcome: PluginExportOutcome) -> String {
        switch outcome {
        case .handled: return "handled by the plugin"
        case .presented: return "shared"
        case .status(let status, let message, let hard):
            return "\(status.rawValue)\(hard ? " (hard)" : "")"
                + (message.map { ": \($0)" } ?? "")
        case .failed(let message, let hard):
            return "failed\(hard ? " (hard)" : ""): \(message)"
        }
    }

    // MARK: - Temporary files

    /// One share's own directory, removed when the sheet closes.
    struct SharedFile {
        let directory: URL
        let file: URL
    }

    /// Hard-links the scratch file under the name the plugin asked for, so the
    /// share sheet offers "Article.epub" rather than "<uuid>-Article.epub".
    static func linkTemporaryFile(at source: URL, name: String) -> SharedFile? {
        let directory = shareDirectory()
        let destination = directory.appendingPathComponent(safeName(name))
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            do {
                try FileManager.default.linkItem(at: source, to: destination)
            } catch {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return SharedFile(directory: directory, file: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    static func writeTemporaryFile(_ data: Data, name: String) -> SharedFile? {
        let directory = shareDirectory()
        let destination = directory.appendingPathComponent(safeName(name))
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return SharedFile(directory: directory, file: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private static func shareDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-export-\(UUID().uuidString)", isDirectory: true)
    }

    static func temporaryName(mime: String?) -> String {
        switch mime {
        case "text/html": return "export.html"
        case "text/markdown": return "export.md"
        case "application/json": return "export.json"
        default: return "export.txt"
        }
    }

    /// A name that cannot escape its directory. The plugin chose it.
    static func safeName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.hasPrefix(".") ? String(cleaned.dropFirst()) : cleaned
        return name.isEmpty ? "export" : String(name.prefix(120))
    }
}

/// The app's share sheet. It resolves a presenter at the moment of the share,
/// because a menu's own view controller is gone by the time a hook settles.
@MainActor
public final class SystemPluginExportSharePresenter: PluginExportSharePresenting {

    public init() {}

    public func presentExportShare(
        items: [Any], from presenter: UIViewController?, sourceView: UIView?,
        completion: @escaping () -> Void
    ) {
        guard let host = presenter ?? PluginExportTopPresenter.current() else {
            completion()
            return
        }
        let activity = UIActivityViewController(
            activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in completion() }
        let anchor = sourceView ?? host.view
        activity.popoverPresentationController?.sourceView = anchor
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: (anchor?.bounds.midX ?? 0), y: (anchor?.bounds.midY ?? 0),
            width: 1, height: 1)
        host.present(activity, animated: true)
    }
}

/// The frontmost view controller of the foreground scene's key window.
public enum PluginExportTopPresenter {

    @MainActor
    public static func current() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
