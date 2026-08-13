//
//  LinkImportRunner.swift
//  LunaReadingList
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

    /// Silences the media Live Activity's start/finish ALERTS — banner, sound and
    /// **haptic** — for the length of a run, called with `true` when it begins
    /// and `false` when it ends. An import of a few hundred social links
    /// otherwise buzzes the device twice per link while the user is watching this
    /// sheet's own progress bar report the same thing.
    func setAlertsSuspended(_ suspended: Bool)

    /// Asks for whatever system permission this batch's downloads will need,
    /// ONCE, before the run starts (Photos access, when downloads are set to land
    /// there and the file holds at least one downloadable link).
    ///
    /// It belongs at the top of the run rather than in the pipeline: the media
    /// path's own prompts arrive either at a transfer's start gate or — in the
    /// Downloader — when the FIRST transfer finishes, i.e. a system alert over
    /// the progress bar minutes in, with a queue behind it that fails as
    /// `.photosPermission` while the user reads it.
    func preflightStorage(forURLStrings urlStrings: [String]) async
}

/// The import's pass over the saves that came back hard-paywalled. Installed by
/// the article `KindWiring`s.
public protocol LinkImportArticleUnlocking: Sendable {
    /// Tries to unlock a hard-paywalled save in a real (off-screen) `WKWebView`,
    /// answering whether the article's content ended up saved.
    ///
    /// The silent tier can't pass a JS paywall or a bot gate, so those saves land
    /// `.needsCaptcha` — titled, tappable, and unread. Doing that pass HERE,
    /// while the user is already waiting on the import, is worth a lot more than
    /// leaving two hundred of them to be tapped one at a time later. It gives up
    /// the moment it meets a CAPTCHA: an unattended flow cannot solve one, and
    /// stopping for it would mean either a stalled bar or a modal thrown over the
    /// top of it. The save stays exactly as it was, for the user to open when
    /// they choose.
    func unlockArticle(itemID: UUID, urlString: String) async -> Bool
}

/// Runs a reviewed batch of imported links through the ordinary save pipeline —
/// one shared ingest per link, the per-app content gate, then the LLM rescue for
/// anything that failed — while reporting one honest overall fraction.
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
            /// Retrying failures with Apple Intelligence.
            case rescuing
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
        /// True once the transfer has finished or failed.
        public let isFinished: Bool

        public init(fraction: Double, isFinished: Bool) {
            self.fraction = fraction
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
    /// follows — a media download, or a rescue.
    static let ingestShare = 0.55
    /// Where a download's or rescue's share ends. Not 1.0: the last sliver lands
    /// when the item is scored, so a finished slice always looks finished.
    static let followUpShare = 0.95
    /// How long an item's own download is waited on before the run moves on and
    /// lets the background transfer finish by itself.
    static let downloadWait: TimeInterval = 180
    private static let downloadPoll: TimeInterval = 0.25
    /// How long an ingest is assumed to take, for the clock-based creep.
    private static let expectedIngestDuration: TimeInterval = 6
    /// The same, for a web unlock — a real page load plus an archive round trip,
    /// so several times an ingest.
    private static let expectedUnlockDuration: TimeInterval = 20

    /// How many links are ingested at once.
    ///
    /// Each is a full page fetch plus an extraction, so this is bounded by the
    /// device rather than by politeness: `activeProcessorCount` halved leaves
    /// extraction headroom, with a floor of 2 (most of the time is network wait,
    /// so even a small device should overlap) and a ceiling of 6, past which
    /// `URLSession`'s own per-host limit and the extractor's memory cost make it
    /// pure contention. Low Power Mode halves it again — the user has asked for
    /// less work and an import is not urgent.
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
    /// Both defaults are the real thing; the seams exist so the ORCHESTRATION —
    /// order, concurrency, scoring, the progress arithmetic, cancellation — is
    /// testable without a network or a language model, which is where this type's
    /// risk actually lives.
    private let ingest: (SavedItem) async -> SurfaceSupport.Decision
    private let rescue: (UUID) async -> Bool
    private let rescueFraction: (UUID) -> Double?
    private let concurrency: Int
    private let clock: () -> Date

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
    /// The slice whose rescue is running, so its fraction can come from the
    /// rescue's own reported stage.
    private var rescuingSlice: (index: Int, itemID: UUID)?
    private var finishedCount = 0
    private var phase: Progress.Phase = .saving
    private var cancelled = false

    public init(
        store: SavesStore = .shared,
        concurrency: Int = LinkImportRunner.defaultConcurrency(),
        clock: @escaping () -> Date = Date.init,
        // `allowsInteractivePrompt: false` does two things here. It suppresses the
        // unsupported-kind modal — `.manual` is an interactive source, so a batch
        // of foreign links would otherwise stack one alert per dropped link on top
        // of the progress sheet. And it makes the ingestor's own `rescueTrigger`
        // non-interactive, so a failure is left for the debounced background sweep
        // instead of starting an inline rescue that would race phase three's
        // awaited one over the same item.
        ingest: @escaping (SavedItem) async -> SurfaceSupport.Decision = {
            await SavesIngestor.shared.ingest($0, allowsInteractivePrompt: false)
        },
        rescue: @escaping (UUID) async -> Bool = {
            await URLRescueCoordinator.shared.rescueAndWait(itemID: $0)
        },
        rescueFraction: @escaping (UUID) -> Double? = {
            URLRescueCoordinator.shared.rescueProgress($0)
        }
    ) {
        self.store = store
        self.concurrency = max(1, concurrency)
        self.clock = clock
        self.ingest = ingest
        self.rescue = rescue
        self.rescueFraction = rescueFraction
    }

    // MARK: - Progress readout

    /// The current overall fraction.
    ///
    /// PULLED by the progress sheet on a display cadence rather than pushed: a
    /// push per byte of several concurrent downloads would post thousands of
    /// notifications a second, and the two legs that advance on a clock (a page
    /// fetch, a model call) have nothing to push anyway.
    public func currentProgress() -> Progress {
        lock.lock()
        let total = slices.count
        let phase = phase
        let finished = finishedCount
        var sum = 0.0
        for (index, value) in slices.enumerated() {
            sum += max(value, estimate(forSlice: index, floor: value))
        }
        let rescuing = rescuingSlice
        lock.unlock()

        // Asked outside the lock: the coordinator takes its own.
        if let rescuing, let fraction = rescueFraction(rescuing.itemID) {
            let span = Self.followUpShare - Self.ingestShare
            let mapped = Self.ingestShare + span * min(1, max(0, fraction))
            lock.lock()
            let floor = slices.indices.contains(rescuing.index) ? slices[rescuing.index] : 0
            lock.unlock()
            sum += max(0, mapped - max(floor, Self.ingestShare))
        }

        guard total > 0 else {
            return Progress(fraction: phase == .done ? 1 : 0, finished: 0, total: 0, phase: phase)
        }
        return Progress(
            fraction: min(1, sum / Double(total)),
            finished: finished, total: total, phase: phase)
    }

    /// The clock-based estimate for a slice whose current leg reports nothing until
    /// it lands — an ingest's page fetch and extraction, or a web unlock. A frozen
    /// bar reads as a hung import, so an open slice eases toward the end of that
    /// leg's stretch. Easing, never linear: an overrunning fetch slows down instead
    /// of stalling at a wall or claiming ground it hasn't earned. Caller holds
    /// `lock`.
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

    /// Saves every candidate in order, ingests them `concurrency`-at-a-time, then
    /// retries the failures with Apple Intelligence one at a time.
    ///
    /// The two phases are separate on purpose. Ingests are IO-bound and parallel;
    /// a rescue is a model call — the one resource on the device that gains
    /// nothing from being asked twice at once, which is why the coordinator's own
    /// background sweep serializes too. Splitting them also keeps the arithmetic
    /// honest: a link that never failed is simply finished at the end of phase one.
    public func run(_ candidates: [Candidate]) async -> Summary {
        var summary = Summary()
        guard !candidates.isEmpty else {
            setPhase(.done)
            return summary
        }

        // Quiet for the whole run, restored however it ends (finished, stopped, or
        // the caller's task cancelled). An import is one operation with one
        // progress bar; it does not need a system alert per link.
        Self.media?.setAlertsSuspended(true)
        defer { Self.media?.setAlertsSuspended(false) }

        // Every permission this batch could need, asked for here and nowhere else.
        // Before the first write, so the answer is in hand by the time a transfer
        // wants it — and before the progress bar starts moving, so the alert isn't
        // an interruption of something already underway.
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
        var failures: [Unit] = []
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
                    // Held open — its slice is finished by the rescue phase.
                    failures.append(work[slice])
                    setSlice(slice, to: Self.ingestShare)
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
            summary.recoverableFailures += failures.count + (work.count - scoredUnits)
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
                _ = await unlocker.unlockArticle(
                    itemID: unit.item.id, urlString: unit.candidate.urlString)
                summary.imported += 1
                complete(slice: unit.slice)
            }
        } else {
            for unit in locked {
                summary.imported += 1
                complete(slice: unit.slice)
            }
        }

        // 4. The LLM rescue, one at a time, before anything is called a failure.
        if !failures.isEmpty { setPhase(.rescuing) }
        for failure in failures {
            guard !isCancelled else {
                summary.recoverableFailures += 1
                complete(slice: failure.slice)
                continue
            }
            beginRescue(slice: failure.slice, itemID: failure.item.id)
            let recovered = await rescue(failure.item.id)
            endRescue()
            if let fresh = store.item(withID: failure.item.id) {
                if recovered, fate(of: fresh).isSaved {
                    summary.imported += 1
                } else {
                    summary.recoverableFailures += 1
                }
            } else {
                // Gone: the rescue landed a kind this app doesn't handle and
                // `applyRescued`'s gate discarded it. The owner isn't reported
                // back through that path, so the summary says only that much.
                summary.rejected.append(
                    RejectedLink(
                        urlString: failure.candidate.urlString,
                        reason: .foreignKind(owner: nil)))
            }
            complete(slice: failure.slice)
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
        let decision = await ingest(item)
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
        case .ready: return .imported
        case .needsCaptcha: return Self.articleUnlocker == nil ? .imported : .locked
        case .failed, .pending: return .failed
        }
    }

    /// Watches this link's media transfer so real bytes drive its slice, instead
    /// of the item reading as done the moment its metadata landed.
    ///
    /// The FIRST look is decisive: the media ingest handler awaits
    /// `LiveMediaDownloadManager.start` before returning, so by the time this
    /// runs the job either exists or was never going to. That is why there's no
    /// grace period here — one would cost every social save that isn't
    /// downloadable a pointless pause, and with a few hundred of them that adds
    /// up to minutes. If that handler ever becomes fire-and-forget the only
    /// consequence is a coarser bar, not a wrong result.
    private func awaitDownload(for item: SavedItem, slice: Int) async {
        guard let media = Self.media,
              media.downloadState(forURLString: item.urlString) != nil else { return }
        let started = clock()
        let span = Self.followUpShare - Self.ingestShare
        while clock().timeIntervalSince(started) < Self.downloadWait, !isCancelled {
            // Finished and reaped.
            guard let state = media.downloadState(forURLString: item.urlString) else { return }
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

    /// The web-unlock leg takes the same stretch a download or a rescue would, and
    /// reports nothing while it runs — a page load, an archive round trip, a DOM
    /// probe — so it is estimated on the clock like an ingest.
    private func beginUnlock(slice: Int) {
        lock.lock()
        creeps[slice] = Creep(
            started: clock(), from: Self.ingestShare, to: Self.followUpShare,
            expected: Self.expectedUnlockDuration)
        lock.unlock()
    }

    private func beginRescue(slice: Int, itemID: UUID) {
        lock.lock()
        creeps[slice] = nil
        rescuingSlice = (slice, itemID)
        lock.unlock()
    }

    private func endRescue() {
        lock.lock()
        rescuingSlice = nil
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
