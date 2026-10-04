//
//  LinkImportRunner.swift
//  LunaSaves
//

import Foundation
import LunaIngest
import LunaModels
import LunaStorage

/// The media leg of an import: watching a transfer, silencing its alerts for the
/// length of the run, and asking for the storage permission the batch will need.
/// Installed by the media `KindWiring`s so this module keeps linking no kind
/// package.
public protocol LinkImportMediaHandling: Sendable {
    /// The live state of the media download for `urlString`, or nil when none is
    /// running.
    func downloadState(forURLString urlString: String) -> LinkImportRunner.MediaDownloadState?

    /// Silences the media Live Activity's start/finish alerts — banner, sound,
    /// and **haptic** — for the length of a run. Call with `true` when the
    /// run begins and `false` when it ends. Without this, an import of a few
    /// hundred social links buzzes the device twice per link while the user
    /// watches this sheet's own progress bar report the same thing.
    func setAlertsSuspended(_ suspended: Bool)

    /// Asks once, before the run starts, for whatever system permission this
    /// batch's downloads will need — Photos access, when downloads are set to
    /// land there and the file holds at least one downloadable link.
    ///
    /// This belongs at the top of the run, not in the pipeline. The media
    /// path's own prompts otherwise arrive either at a transfer's start gate
    /// or, in the Downloader, when the first transfer finishes — a system
    /// alert over the progress bar minutes in, with a queue behind it that
    /// fails as `.photosPermission` while the user is still reading the
    /// prompt.
    func preflightStorage(forURLStrings urlStrings: [String]) async
}

/// The import's pass over the saves that came back hard-paywalled. Installed by
/// the article `KindWiring`s.
public protocol LinkImportArticleUnlocking: Sendable {
    /// Tries to unlock a hard-paywalled save in a real, off-screen `WKWebView`,
    /// and answers whether the article's content ended up saved.
    ///
    /// The silent tier cannot pass a JS paywall or a bot gate, so those saves
    /// land as `.needsCaptcha` — titled, tappable, and unread. Trying again
    /// here, while the user is already waiting on the import, saves them from
    /// tapping two hundred saves open one at a time later. This gives up the
    /// moment it meets a CAPTCHA: an unattended flow cannot solve one, and
    /// stopping for it would mean either a stalled progress bar or a modal
    /// thrown over the top of it. The save stays exactly as it was, for the
    /// user to open when they choose.
    func unlockArticle(itemID: UUID, urlString: String) async -> Bool
}

/// Runs a reviewed batch of imported links through the ordinary save pipeline —
/// one shared ingest per link, the per-app content gate, then a browser pass
/// over the locked ones — while reporting one honest overall fraction. A link
/// that fails ends the run as a recoverable failure; its own `.failed` fires
/// the ordinary automatic rescue, the same as any other save.
///
/// See `claudedocs/import-export.md`. Deliberately kind-neutral: a media
/// download is observed through an installed protocol witness (`media`), so this
/// module keeps linking no kind package.
public final class LinkImportRunner {

    // MARK: - Inputs

    /// A link the user kept in the review sheet.
    public struct Candidate: Equatable, Sendable {
        public let urlString: String
        public let isArchived: Bool

        public init(urlString: String, isArchived: Bool) {
            self.urlString = urlString
            self.isArchived = isArchived
        }
    }

    // MARK: - Outcomes

    /// Why a link didn't land.
    public enum Rejection: Equatable, Sendable {
        /// Classified into a kind this app doesn't handle. `owner` is the sibling
        /// app that does — nil when the drop happened inside the Apple
        /// Intelligence retry, which reports only that the item was discarded.
        case foreignKind(owner: LunaApp?)
        /// Nothing usable could be made of the URL itself.
        case unusableURL
    }

    public struct RejectedLink: Equatable, Sendable {
        public let urlString: String
        public let reason: Rejection

        public init(urlString: String, reason: Rejection) {
            self.urlString = urlString
            self.reason = reason
        }
    }

    /// The end-of-run report.
    public struct Summary: Equatable, Sendable {
        /// Saved and usable — content ready, a hard paywall parked for unlocking,
        /// or a media item in the library.
        public var imported: Int = 0
        /// Saved, but the content didn't come down. Real saves that Luna retries
        /// by itself on the next launch, hence "recoverable".
        public var recoverableFailures: Int = 0
        /// Already in the list before the import; nothing was written.
        public var duplicates: Int = 0
        /// Dropped, with the URL, so the summary can list them.
        public var rejected: [RejectedLink] = []
        /// Set when the user stopped the run.
        public var wasCancelled: Bool = false

        public init() {}

        public var total: Int {
            imported + recoverableFailures + duplicates + rejected.count
        }
    }

    /// A live snapshot for the progress bar.
    public struct Progress: Equatable, Sendable {
        /// 0…1 over the whole run.
        public let fraction: Double
        /// How many links have reached a final state.
        public let finished: Int
        public let total: Int
        public let phase: Phase

        public enum Phase: Equatable, Sendable {
            case saving
            case fetching
            /// Opening the locked articles in a real browser, out of sight.
            case unlocking
            case done
        }

        public init(fraction: Double, finished: Int, total: Int, phase: Phase) {
            self.fraction = fraction
            self.finished = finished
            self.total = total
            self.phase = phase
        }
    }

    // MARK: - Injected seams

    /// The live state of a media download, or nil when none is running for that URL.
    public struct MediaDownloadState: Equatable, Sendable {
        public let fraction: Double
        /// Raw transfer progress when the downloader knows it. Unlike a rounded
        /// fraction, this advances for unknown/very large payloads and lets the
        /// import distinguish a slow stream from thirty seconds of silence.
        public let receivedByteCount: Int64?
        /// True once the transfer has finished or failed.
        public let isFinished: Bool

        public init(
            fraction: Double, receivedByteCount: Int64? = nil, isFinished: Bool
        ) {
            self.fraction = fraction
            self.receivedByteCount = receivedByteCount
            self.isFinished = isFinished
        }
    }

    /// The media leg of an import, installed by the media `KindWiring`s over
    /// `LiveMediaDownloadManager` / `MediaPhotosPreflight`
    /// (`Luna/MediaShellWiring.swift`). Left uninstalled in Reader and Price
    /// Tracker, where a media link can never pass the content gate.
    public static var media: (any LinkImportMediaHandling)?

    /// The article-unlock leg of an import, installed by the article
    /// `KindWiring`s over `UnattendedArticleUnlock`. Left uninstalled in the
    /// Downloader and Price Tracker, where no article save exists to unlock.
    public static var articleUnlocker: (any LinkImportArticleUnlocking)?

    // MARK: - Tunables

    /// The share of an item's slice its ingest owns; the rest belongs to whatever
    /// follows — a media download, or a browser unlock.
    static let ingestShare = 0.55
    /// Where a download's or an unlock's share ends. Not 1.0: the last sliver lands
    /// when the item is scored, so a finished slice always looks finished.
    static let followUpShare = 0.95
    /// How long an item's own download is waited on before the run moves on and
    /// lets the background transfer finish by itself.
    static let downloadWait: TimeInterval = 180
    /// A transfer may exceed `downloadWait` while it continues in the background,
    /// but the import itself stops waiting after this much silence.
    public static let perLinkIdleTimeout: TimeInterval = 30
    private static let downloadPoll: TimeInterval = 0.25
    /// How long an ingest is assumed to take, for the clock-based creep.
    private static let expectedIngestDuration: TimeInterval = 6
    /// The same, for a web unlock — a real page load plus an archive round trip,
    /// so several times an ingest.
    private static let expectedUnlockDuration: TimeInterval = 20

    /// How many links are ingested at once.
    ///
    /// Each ingest is a full page fetch plus an extraction, so this bounds by
    /// the device rather than by politeness. `activeProcessorCount` halved
    /// leaves extraction headroom. The floor is 2, since most of the time is
    /// network wait, so even a small device should overlap. The ceiling is 6:
    /// past that, `URLSession`'s own per-host limit and the extractor's
    /// memory cost make more concurrency pure contention. Low Power Mode
    /// halves it again — the user has asked for less work, and an import is
    /// not urgent.
    public static func defaultConcurrency(
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) -> Int {
        let base = min(6, max(2, processorCount / 2))
        return isLowPowerMode ? max(1, base / 2) : base
    }

    // MARK: - State

    private let store: SavesStore
    /// The two operations a link goes through, injected rather than reached for.
    ///
    /// Both defaults are the real thing. The seams exist so the
    /// orchestration — order, concurrency, scoring, the progress arithmetic,
    /// cancellation — is testable without a network or a language model,
    /// which is where this type's real risk lives.
    private let ingest: (SavedItem) async -> SurfaceSupport.Decision
    private let concurrency: Int
    private let clock: () -> Date
    private let idleTimeout: TimeInterval

    /// Everything below is guarded by `lock`.
    private let lock = NSLock()
    /// Per-slice progress, one slice per link that was really inserted.
    private var slices: [Double] = []
    private var sliceIndexByItem: [UUID: Int] = [:]
    /// A leg that reports nothing until it lands, and so has to be estimated from
    /// the clock: which stretch of the slice it owns, when it started, and how long
    /// its kind of work usually takes.
    private struct Creep {
        let started: Date
        let from: Double
        let to: Double
        let expected: TimeInterval
    }
    /// The in-flight clock-estimated leg per slice, if any.
    private var creeps: [Int: Creep] = [:]
    private var finishedCount = 0
    private var phase: Progress.Phase = .saving
    private var cancelled = false

    public init(
        store: SavesStore = .shared,
        concurrency: Int = LinkImportRunner.defaultConcurrency(),
        clock: @escaping () -> Date = Date.init,
        idleTimeout: TimeInterval = LinkImportRunner.perLinkIdleTimeout,
        // `allowsInteractivePrompt: false` suppresses the unsupported-kind modal
        // — `.manual` is an interactive source, so a batch of foreign links would
        // otherwise stack one alert per dropped link on top of the progress sheet.
        ingest: @escaping (SavedItem) async -> SurfaceSupport.Decision = {
            await SavesIngestor.shared.ingest($0, allowsInteractivePrompt: false)
        }
    ) {
        self.store = store
        self.concurrency = max(1, concurrency)
        self.clock = clock
        self.idleTimeout = max(0, idleTimeout)
        self.ingest = ingest
    }

    // MARK: - Progress readout

    /// The current overall fraction.
    ///
    /// The progress sheet pulls this on a display cadence rather than being
    /// pushed to: a push per byte of several concurrent downloads would post
    /// thousands of notifications a second, and the two legs that advance on
    /// a clock — a page fetch, a model call — have nothing to push anyway.
    public func currentProgress() -> Progress {
        lock.lock()
        let total = slices.count
        let phase = phase
        let finished = finishedCount
        var sum = 0.0
        for (index, value) in slices.enumerated() {
            sum += max(value, estimate(forSlice: index, floor: value))
        }
        lock.unlock()

        guard total > 0 else {
            return Progress(fraction: phase == .done ? 1 : 0, finished: 0, total: 0, phase: phase)
        }
        return Progress(
            fraction: min(1, sum / Double(total)),
            finished: finished, total: total, phase: phase)
    }

    /// The clock-based estimate for a slice whose current leg reports nothing
    /// until it lands — an ingest's page fetch and extraction, or a web
    /// unlock. A frozen bar reads as a hung import, so an open slice eases
    /// toward the end of that leg's stretch. The ease is never linear: an
    /// overrunning fetch slows down instead of stalling at a wall or claiming
    /// ground it has not earned. The caller holds `lock`.
    private func estimate(forSlice index: Int, floor: Double) -> Double {
        guard let creep = creeps[index] else { return floor }
        let elapsed = max(0, clock().timeIntervalSince(creep.started))
        let eased = 1 - exp(-elapsed / creep.expected)
        return max(floor, creep.from + (creep.to - creep.from) * eased * 0.9)
    }

    /// Stops the run. In-flight links finish; unreached ones stay saved and
    /// pending, which Luna's ordinary launch sweep picks up.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    // MARK: - Run

    /// Saves every candidate in order, ingests them `concurrency` at a time,
    /// then opens the hard-paywalled ones in a real browser, one at a time.
    ///
    /// The two phases are separate on purpose. Ingests are IO-bound and run in
    /// parallel; an unlock is a whole `WKWebView` and two of them racing
    /// archive.today is the fastest way to be rate-limited. Splitting them also
    /// keeps the arithmetic honest: a link that never locked is simply finished
    /// at the end of phase one.
    public func run(_ candidates: [Candidate]) async -> Summary {
        var summary = Summary()
        guard !candidates.isEmpty else {
            setPhase(.done)
            return summary
        }

        // Quiet for the whole run, restored however it ends — finished,
        // stopped, or the caller's task cancelled. An import is one operation
        // with one progress bar; it does not need a system alert per link.
        Self.media?.setAlertsSuspended(true)
        defer { Self.media?.setAlertsSuspended(false) }

        // Asks for every permission this batch could need, here and nowhere
        // else — before the first write, so the answer is in hand by the
        // time a transfer wants it, and before the progress bar starts
        // moving, so the prompt is not an interruption of something already
        // underway.
        await Self.media?.preflightStorage(forURLStrings: candidates.map(\.urlString))

        // 1. One coordinated write for the whole batch, in the file's order.
        let placements = store.insertImported(
            candidates.map {
                SavesStore.ImportedLink(
                    urlString: $0.urlString, isArchived: $0.isArchived)
            },
            source: .manual)

        // Only newly inserted links have work to do; a duplicate is reported and
        // left exactly as the user already had it.
        var work: [Unit] = []
        for (candidate, placement) in zip(candidates, placements) {
            guard placement.wasInserted else {
                summary.duplicates += 1
                continue
            }
            guard placement.item.url != nil else {
                // The parser validated the string, but a stored value that no
                // longer makes a URL is rejected rather than ingested.
                store.delete(placement.item)
                summary.rejected.append(
                    RejectedLink(urlString: candidate.urlString, reason: .unusableURL))
                continue
            }
            work.append(Unit(slice: work.count, item: placement.item, candidate: candidate))
        }

        lock.withLock {
            slices = Array(repeating: 0, count: work.count)
            sliceIndexByItem = Dictionary(
                work.map { ($0.item.id, $0.slice) }, uniquingKeysWith: { first, _ in first })
            phase = work.isEmpty ? .done : .fetching
        }
        guard !work.isEmpty else { return summary }

        // 2. Ingest, `concurrency` at a time, in order.
        var locked: [Unit] = []
        var scoredUnits = 0
        await withTaskGroup(of: (Int, ItemFate).self) { group in
            var next = 0
            var running = 0
            while true {
                while running < concurrency, next < work.count, !isCancelled {
                    let unit = work[next]
                    next += 1
                    running += 1
                    group.addTask { [weak self] in
                        guard let self else { return (unit.slice, .abandoned) }
                        return (unit.slice, await self.ingestOne(unit.item))
                    }
                }
                guard running > 0, let (slice, fate) = await group.next() else { break }
                running -= 1
                scoredUnits += 1
                switch fate {
                case .imported:
                    summary.imported += 1
                    complete(slice: slice)
                case let .rejected(owner):
                    summary.rejected.append(
                        RejectedLink(
                            urlString: work[slice].candidate.urlString,
                            reason: .foreignKind(owner: owner)))
                    complete(slice: slice)
                case .locked:
                    // A working save already (titled, tappable) — held open so the
                    // web-unlock phase can try to fill it in. Scored there either
                    // way, as imported.
                    locked.append(work[slice])
                    setSlice(slice, to: Self.ingestShare)
                case .failed:
                    // The save's own `.failed` fires the automatic rescue, which
                    // runs on its own clock; the import does not wait for it.
                    summary.recoverableFailures += 1
                    complete(slice: slice)
                case .abandoned:
                    summary.recoverableFailures += 1
                    complete(slice: slice)
                }
            }
        }

        // Whatever the cancel skipped is saved and pending, so Luna's own sweep
        // finishes it: recoverable, not lost.
        if isCancelled {
            summary.wasCancelled = true
            summary.imported += locked.count
            summary.recoverableFailures += work.count - scoredUnits
            for slice in 0..<work.count { complete(slice: slice) }
            setPhase(.done)
            return summary
        }

        // 3. The locked articles, in a real browser, one at a time and out of
        // sight. Serial because it is a WKWebView per attempt, and because two of
        // them racing archive.today is the fastest way to be rate-limited.
        if let unlocker = Self.articleUnlocker, !locked.isEmpty {
            setPhase(.unlocking)
            for unit in locked {
                guard !isCancelled else {
                    summary.imported += 1
                    complete(slice: unit.slice)
                    continue
                }
                beginUnlock(slice: unit.slice)
                // The outcome doesn't change the score: a locked save counts as
                // imported either way — it is titled and it opens. Unlocking now
                // just means the user doesn't have to tap it later.
                let unlocked = await IdleTimeLimit.run(idleTimeout) {
                    await unlocker.unlockArticle(
                        itemID: unit.item.id, urlString: unit.candidate.urlString)
                }
                if unlocked == nil {
                    SharedDiagnosticLog.record(
                        "bulk import: \(Int(idleTimeout))s idle timeout unlocking "
                            + unit.candidate.urlString,
                        category: "archive")
                }
                summary.imported += 1
                complete(slice: unit.slice)
            }
        } else {
            for unit in locked {
                summary.imported += 1
                complete(slice: unit.slice)
            }
        }

        summary.wasCancelled = isCancelled
        setPhase(.done)
        return summary
    }

    // MARK: - One link

    private struct Unit {
        let slice: Int
        let item: SavedItem
        let candidate: Candidate
    }

    private enum ItemFate: Sendable {
        case imported
        /// Saved and titled, but hard-paywalled — worth one web-unlock attempt
        /// before the run ends. Only reported when an unlocker is installed;
        /// otherwise this is `.imported`, which is what it has always been.
        case locked
        case rejected(owner: LunaApp)
        case failed
        /// The runner went away mid-flight: saved, not fetched.
        case abandoned

        /// Whether the item ended up usable, however it got there.
        var isSaved: Bool {
            switch self {
            case .imported, .locked: return true
            case .rejected, .failed, .abandoned: return false
            }
        }
    }

    private func ingestOne(_ item: SavedItem) async -> ItemFate {
        let slice = sliceIndex(forItem: item)
        beginIngest(slice: slice)
        guard let decision = await IdleTimeLimit.run(idleTimeout, operation: {
            await self.ingest(item)
        }) else {
            // Every candidate was inserted before this phase, so abandoning an
            // unresponsive worker loses nothing: the placeholder remains durable
            // and the ordinary launch sweep can retry it. Crucially, the task
            // group's worker itself returns, freeing its concurrency slot and
            // allowing the batch to finish.
            SharedDiagnosticLog.record(
                "bulk import: \(Int(idleTimeout))s idle timeout for \(item.urlString)",
                category: "ingest")
            return .abandoned
        }
        if case let .unsupported(owner) = decision { return .rejected(owner: owner) }
        setSlice(slice, to: Self.ingestShare)

        guard let fresh = store.item(withID: item.id) else {
            // Gone without an unsupported decision: the pipeline resolved it onto
            // a URL another save already held, and it merged into that one.
            return .imported
        }
        // Only a platform save can have started a transfer, and finding out costs
        // a two-second wait — so an article never pays it.
        if fresh.platform != nil {
            await awaitDownload(for: fresh, slice: slice)
        }
        guard let settled = store.item(withID: item.id) else { return .imported }
        return fate(of: settled)
    }

    /// The stored state read as an import outcome. `.needsCaptcha` is never a
    /// failure: it's a titled save the user unlocks by tapping it — a working item,
    /// not something to retry. It comes back `.locked` when there's an unlocker to
    /// try it with, and `.imported` when there isn't.
    private func fate(of item: SavedItem) -> ItemFate {
        switch item.state {
        case .link, .ready: return .imported
        case .needsCaptcha: return Self.articleUnlocker == nil ? .imported : .locked
        case .failed, .pending: return .failed
        }
    }

    /// Watches this link's media transfer so real bytes drive its slice,
    /// instead of the item reading as done the moment its metadata landed.
    ///
    /// The first look is decisive: the media ingest handler awaits
    /// `LiveMediaDownloadManager.start` before returning, so by the time
    /// this runs the job either exists or was never going to. That is why
    /// there is no grace period here — one would cost every social save that
    /// is not downloadable a pointless pause, and a few hundred of them add
    /// up to minutes. If that handler ever becomes fire-and-forget, the only
    /// consequence is a coarser bar, not a wrong result.
    private func awaitDownload(for item: SavedItem, slice: Int) async {
        guard let media = Self.media,
              media.downloadState(forURLString: item.urlString) != nil else { return }
        let started = clock()
        var lastActivity = started
        var lastFraction = -1.0
        var lastReceivedByteCount: Int64?
        let span = Self.followUpShare - Self.ingestShare
        while clock().timeIntervalSince(started) < Self.downloadWait,
              clock().timeIntervalSince(lastActivity) < idleTimeout,
              !isCancelled {
            // Finished and reaped.
            guard let state = media.downloadState(forURLString: item.urlString) else { return }
            if state.fraction > lastFraction
                || state.receivedByteCount.map({ $0 > (lastReceivedByteCount ?? -1) }) == true {
                lastActivity = clock()
                lastFraction = state.fraction
                lastReceivedByteCount = state.receivedByteCount
            }
            setSlice(slice, to: Self.ingestShare + span * min(1, max(0, state.fraction)))
            if state.isFinished { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.downloadPoll * 1_000_000_000))
        }
    }

    // MARK: - Slice bookkeeping

    private func sliceIndex(forItem item: SavedItem) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sliceIndexByItem[item.id] ?? 0
    }

    private func beginIngest(slice: Int) {
        lock.lock()
        creeps[slice] = Creep(
            started: clock(), from: 0, to: Self.ingestShare,
            expected: Self.expectedIngestDuration)
        lock.unlock()
    }

    /// The web-unlock leg takes the same stretch a download would, and
    /// reports nothing while it runs — a page load, an archive round trip, a DOM
    /// probe — so it is estimated on the clock like an ingest.
    private func beginUnlock(slice: Int) {
        lock.lock()
        creeps[slice] = Creep(
            started: clock(), from: Self.ingestShare, to: Self.followUpShare,
            expected: Self.expectedUnlockDuration)
        lock.unlock()
    }

    private func setSlice(_ index: Int, to value: Double) {
        lock.lock()
        if slices.indices.contains(index) {
            slices[index] = max(slices[index], value) // Never backward.
        }
        creeps[index] = nil
        lock.unlock()
    }

    private func complete(slice index: Int) {
        lock.lock()
        if slices.indices.contains(index), slices[index] < 1 {
            slices[index] = 1
            finishedCount += 1
        }
        creeps[index] = nil
        lock.unlock()
    }

    private func setPhase(_ value: Progress.Phase) {
        lock.lock()
        phase = value
        lock.unlock()
    }
}
