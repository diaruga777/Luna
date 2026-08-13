//
//  LunaStage.swift
//  Luna
//

import LunaAppConfig
import LunaModels
import UIKit

/// **Staged mode**: launch any app straight into any screen, in any state, with
/// stubbed data and nothing persisted. `claudedocs/staging.md`.
///
/// ```sh
/// xcrun simctl launch <sim> com.hsanabria.luna.reader -LunaStage reader.rsvp
/// ```
///
/// The point is a screenshot loop that costs one `simctl launch` per screen
/// instead of a navigation script per screen: no onboarding to answer, no
/// account to connect, no permission sheet, and the same state every run.
///
/// Staged mode is the four-app, four-surface version of the same idea: a
/// registry rather than an enum, per-kind catalogs so a single-kind app only
/// knows its own screens, a throwaway container so a run leaves nothing
/// behind, and a manifest an agent can enumerate without reading Swift.
///
/// DEBUG-only, and the gate is `#if DEBUG` rather than a build setting on
/// purpose. The stage catalogs reference `seedForTesting`, `SavedItem
/// (seed:)`, and the other DEBUG-only fixture seams, so a release build
/// cannot compile them even if someone passes the launch argument. There is
/// nothing to disable: in a shipped binary, this file is just an `isActive`
/// that returns false.
enum LunaStage {

    /// `-LunaStage <id>` — boot into that stage.
    static let stageArgument = "-LunaStage"
    /// `-LunaStageList` — print the manifest as JSON on stdout and exit.
    static let listArgument = "-LunaStageList"

    /// Whether this process was launched into staged mode. Readable from
    /// release code (it is constantly false there), so the launch-time network
    /// and background work can be gated on it without `#if` at every site.
    static var isActive: Bool {
        #if DEBUG
        return requestedID != nil || isListRequested
        #else
        return false
        #endif
    }

    #if DEBUG

    /// The stage id asked for on the command line, if any.
    static var requestedID: String? { argumentValue(for: stageArgument) }

    /// Whether the manifest was asked for instead of a screen.
    static var isListRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(listArgument)
    }

    /// Step 1, the very first thing `didFinishLaunching` does: point every
    /// App-Group-backed store at a throwaway container, before anything can
    /// resolve the real one. Everything after this — including the app's own
    /// launch bookkeeping — writes to scratch.
    ///
    /// Animations stay on deliberately. Turning them off globally looks like
    /// the obvious way to make a capture deterministic, but it is wrong
    /// here: the card carousel mounts its cards through an animated path, so
    /// `UIView.setAnimationsEnabled(false)` rendered every deck stage as a
    /// black screen. Determinism comes from the harness instead: the capture
    /// script (`scripts/stage_screenshots.py`) waits for two identical
    /// frames rather than a fixed delay, which is both more accurate and
    /// impossible to get wrong from inside the app.
    static func prepareIfNeeded() {
        guard isActive else { return }
        StageContainer.activate(identifier: requestedID ?? "list")
    }

    /// Step 3, the last thing `didFinishLaunching` does — by which point every
    /// catalog has been installed by `KindWiring.install()`. Answers
    /// `-LunaStageList` and gets out of the way.
    static func finishLaunchIfNeeded() {
        guard isListRequested else { return }
        print(StageRegistry.manifestJSON(for: .current))
        // stdout is line-buffered through `simctl launch --console-pty`; the
        // exit below can outrun it otherwise.
        fflush(stdout)
        exit(0)
    }

    /// Step 4, from `SceneDelegate`: seeds the stage's fixtures and builds
    /// its screen. Returns nil when no stage was requested (a production
    /// launch) or when the stage asked for the app's own root — the caller
    /// then carries on down the normal path with the store already seeded.
    ///
    /// An unknown id is a hard failure, not a silent fall-through to the
    /// normal root: a screenshot run that quietly captured the wrong screen
    /// for a typo'd id is worse than one that stops.
    @MainActor
    static func rootViewController() -> UIViewController? {
        guard let requestedID else { return nil }
        guard let stage = StageRegistry.stage(id: requestedID) else {
            let known = StageRegistry.all(for: .current).map(\.id).joined(separator: "\n  ")
            fatalError("""
                Unknown -LunaStage id "\(requestedID)". \
                Stages available in \(LunaApp.current.storageIdentifier):
                  \(known)
                """)
        }
        stage.seed?()
        return stage.make?()
    }

    private static func argumentValue(for key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    #endif
}

#if DEBUG

/// One entry in the stage catalog: a screen, a state it can be in, the fixture
/// that puts it there, and which apps the pair means anything in.
struct StageDescriptor {

    /// Which kind's catalog a stage came from — and so, by construction, which
    /// apps could possibly show it. A stage cannot be in a wider set than its
    /// kind allows; `StageRegistryTests` enforces that.
    enum Kind: String, CaseIterable {
        /// Every app: the deck itself, settings, appearance, the util card.
        case shared
        /// Article-handling apps: readers, audio, article cards.
        case article
        /// The two apps that connect a sending account (`LunaApp.sharesByEmail`).
        /// Same app set as `article` today, different reason — an app could
        /// gain articles without gaining email.
        case email
        /// Media-handling apps: saved media, download states.
        case media
        /// Product-handling apps: trackers, the price graph, alerts.
        case product

        /// The apps this kind is compiled into. The default `apps` for a stage.
        var apps: [LunaApp] {
            switch self {
            case .shared: return LunaApp.allCases
            case .article: return LunaApp.allCases.filter(\.handlesArticles)
            case .email: return LunaApp.allCases.filter(\.sharesByEmail)
            case .media: return LunaApp.allCases.filter(\.handlesMedia)
            case .product: return LunaApp.allCases.filter(\.handlesProducts)
            }
        }
    }

    /// Stable identifier, `<area>.<screen>.<variant>` — what `-LunaStage`
    /// takes. Not a user-visible string (no `L10n`): it is an API the
    /// screenshot harness and any driving agent type verbatim.
    let id: String
    /// Human grouping for the guide, e.g. "Card deck".
    let screen: String
    /// The state within that screen, e.g. "empty".
    let variant: String
    /// One line saying what a reviewer should be looking at.
    let summary: String
    let kind: Kind
    /// Apps this stage means something in — never wider than `kind.apps`.
    let apps: [LunaApp]
    /// Puts the world into the state the screen reads. Runs before `make`, and
    /// before the app's own root is built for a deck stage.
    let seed: (@MainActor () -> Void)?
    /// Builds the screen. **nil means "the app's own root"** — the deck stages
    /// want exactly what production builds, seeded differently, which is the
    /// whole point of not hand-rolling a deck here.
    let make: (@MainActor () -> UIViewController?)?

    init(
        id: String, screen: String, variant: String, summary: String,
        kind: Kind, apps: [LunaApp]? = nil,
        seed: (@MainActor () -> Void)? = nil,
        make: (@MainActor () -> UIViewController?)? = nil
    ) {
        self.id = id
        self.screen = screen
        self.variant = variant
        self.summary = summary
        self.kind = kind
        self.apps = apps ?? kind.apps
        self.seed = seed
        self.make = make
    }
}

/// The one place every stage is registered, and the one place anything reads
/// them back. Each kind's catalog calls `register` from `KindWiring.install()`,
/// so an app only ever holds the stages for the kinds it links — the same
/// composition rule the ingest kind packs follow
/// (`claudedocs/surface-support.md`).
enum StageRegistry {

    private(set) static var registered: [String: StageDescriptor] = [:]

    /// Registers a catalog's stages. A duplicate id is a programming error —
    /// two stages answering to one `-LunaStage` would make a capture
    /// nondeterministic — so it trips here rather than silently winning.
    static func register(_ stages: [StageDescriptor]) {
        for stage in stages {
            if let existing = registered[stage.id], existing.screen != stage.screen {
                assertionFailure("duplicate stage id \(stage.id)")
            }
            registered[stage.id] = stage
        }
    }

    /// Every stage this process knows about, id-sorted.
    static var all: [StageDescriptor] {
        registered.values.sorted { $0.id < $1.id }
    }

    /// The stages that mean something in `app`.
    static func all(for app: LunaApp) -> [StageDescriptor] {
        all.filter { $0.apps.contains(app) }
    }

    static func stage(id: String) -> StageDescriptor? { registered[id] }

    /// Test seam — the suite installs catalogs itself and must not inherit the
    /// host app's launch-time registration.
    static func resetForTesting() { registered = [:] }

    /// The manifest an agent enumerates instead of reading Swift: every stage
    /// this app can run, as JSON on stdout (`-LunaStageList`).
    ///
    /// Hand-rolled rather than `JSONEncoder` for one reason — the committed
    /// `Luna/Stage/StageManifest.json` is diffed against this string by
    /// `StageRegistryTests`, so the formatting has to be stable and readable in
    /// a review, not just valid.
    static func manifestJSON(for app: LunaApp) -> String {
        let stages = all(for: app)
        var lines: [String] = ["{", "  \"app\": \"\(app.storageIdentifier)\",", "  \"stages\": ["]
        for (index, stage) in stages.enumerated() {
            let apps = stage.apps.map { "\"\($0.storageIdentifier)\"" }.joined(separator: ", ")
            lines.append("    {")
            lines.append("      \"id\": \"\(stage.id)\",")
            lines.append("      \"screen\": \(quoted(stage.screen)),")
            lines.append("      \"variant\": \(quoted(stage.variant)),")
            lines.append("      \"summary\": \(quoted(stage.summary)),")
            lines.append("      \"kind\": \"\(stage.kind.rawValue)\",")
            lines.append("      \"apps\": [\(apps)]")
            lines.append("    }" + (index == stages.count - 1 ? "" : ","))
        }
        lines.append("  ]")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}

#endif
