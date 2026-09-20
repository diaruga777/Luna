//
//  LunaFileIntake.swift
//  LunaModels
//

import Foundation
import LunaAppConfig
import os

/// What a Luna file turned out to hold.
public enum LunaFileKind: Equatable, Sendable {
    /// A plugin draft: the manifest JSON from the header, and the whole file
    /// (header included) as the source the importer reads.
    case plugin(headerJSON: String, source: String)
    /// A recovered save.
    case recovery(LunaRecoveryFile)
}

/// Whoever turns an arriving recovery file into a save the user sees. One
/// witness per process, installed by that process's composition root, so the
/// app, the share extension and the action extension each dispatch a file the
/// way their own surface can.
///
/// The recovery half and the plugin half are separate seams because different
/// tiers own them: recovery lives in every app, plugins only in central Luna.
@MainActor
public protocol LunaRecoveryFileHandling: AnyObject {
    /// `sourceURL` is the file the user opened, when there was one — Open In
    /// and Files give one, a pasted code block does not.
    func handleRecovery(_ file: LunaRecoveryFile, sourceURL: URL?)
}

/// Whoever turns an arriving plugin draft into a review screen. Central Luna
/// installs a real witness; the sibling apps link no plugin tier and keep the
/// unsupported one.
@MainActor
public protocol LunaPluginFileHandling: AnyObject {
    func handlePlugin(source: String, headerJSON: String)
}

/// Reads a Luna file, and hands it to the surface's own handler.
///
/// Classification is pure, so every surface answers "is this a Luna file, and
/// what is in it" the same way (`claudedocs/luna-file.md`).
public enum LunaFileIntake {

    /// This process's recovery handler. A strong protocol witness rather than a
    /// stored closure: it is a launch seam, installed once by the composition
    /// root.
    @MainActor
    public static var recoveryHandler: (any LunaRecoveryFileHandling)?

    /// This process's plugin-draft handler, installed the same way.
    @MainActor
    public static var pluginHandler: (any LunaPluginFileHandling)?

    /// A cheap prefix test for the share sheet's plain-text route, which must
    /// not run a full parse over every shared caption. A true answer still
    /// goes through `classify`.
    public static func looksLikeLunaFile(text: String) -> Bool {
        let head = text.prefix(1_024).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("/*") else { return false }
        let marker = head.dropFirst(2).prefix { $0 != "\n" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LunaFileMarker(rawValue: marker) != nil
    }

    /// The Luna file `text` holds, the error that stopped a recognized one, or
    /// **nil when `text` is not a Luna file at all** — no header comment, or a
    /// marker Luna does not know. A caller shows nothing for nil and the
    /// error's `message` for a failure.
    public static func classify(text: String) -> Result<LunaFileKind, LunaFileError>? {
        let header: LunaFileHeader
        switch LunaFileHeader.parse(text) {
        case .success(let parsed): header = parsed
        case .failure(.noHeader): return nil
        case .failure(let error): return .failure(error)
        }
        switch header.marker {
        case .plugin:
            return .success(.plugin(headerJSON: header.json, source: text))
        case .recovery:
            return LunaRecoveryFile.parse(header).map { .recovery($0) }
        }
    }
}

/// The handler a surface installs when it has no real one. It records the
/// arrival in the log and shows nothing, so a Luna file reaching a surface that
/// cannot present it is visible in diagnostics rather than silent.
public final class UnsupportedLunaFileIntake: LunaRecoveryFileHandling, LunaPluginFileHandling {
    private static let log = Logger(subsystem: LunaLogging.subsystem, category: "lunafile")

    public init() {}

    public func handleRecovery(_ file: LunaRecoveryFile, sourceURL: URL?) {
        Self.log.info("recovery Luna file arrived with no handler installed")
    }

    public func handlePlugin(source: String, headerJSON: String) {
        Self.log.info("plugin Luna file arrived with no handler installed")
    }
}
