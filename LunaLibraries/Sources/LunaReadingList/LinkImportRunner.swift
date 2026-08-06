//
//  LinkImportRunner.swift
//  LunaReadingList
//

import Foundation
import LunaIngest
import LunaModels
import LunaStorage

/// Runs a reviewed batch of imported links through the ordinary save pipeline —
/// one shared ingest per link, the per-app content gate, then the LLM rescue for
/// anything that failed — while reporting one honest overall fraction.
///
/// See `claudedocs/import-export.md`. Deliberately kind-neutral: a media
/// download is observed through an injected seam (`mediaDownloadProgress`), so
/// this module keeps linking no kind package.
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

    /// Installed by the media `KindWiring`s over `LiveMediaDownloadManager`
    /// (`Luna/KindWiring+Luna.swift`, `+Downloader.swift`). Left nil in Reader and
    /// Price Tracker, where a media link can never pass the content gate, so
    /// there is nothing to watch.
    public static var mediaDownloadProgress: (@Sendable (String) -> MediaDownloadState?)?

    /// Silences the media Live Activity's start/finish ALERTS — banner, sound and
    /// **haptic** — for the length of a run, called with `true` when it begins and
    /// `false` when it ends. An import of a few hundred social links otherwise
    /// buzzes the device twice per link while the user is watching this sheet's own
    /// progress bar report the same thing. Installed by the media `KindWiring`s
    /// (nil elsewhere: no media link can pass those apps' content gate, so there
    /// is no transfer to alert about).
    public static var mediaAlertSuspension: (@Sendable (Bool) -> Void)?

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

    private let store: ReadingListStore
    /// The two operations a link goes through, injected rather than reached for.
    ///
    /// Both defaults are the real thing; the seams exist so the ORCHESTRATION —
    /// order, concurrency, scoring, the progress arithmetic, cancellation — is
    /// testable without a network or a language model, which is where this type's
    /// risk actually lives.
    private let ingest: (ReadingListItem) async -> SurfaceSupport.Decision
    private let rescue: (UUID) async -> Bool
    private let rescueFraction: (UUID) -> Double?
    private let concurrency: Int
    private let clock: () -> Date

    /// Everything below is guarded by `lock`.
    private let lock = NSLock()
    /// Per-slice progress, one slice per link that was really inserted.
    private var slices: [Double] = []
    private var sliceIndexByItem: [UUID: Int] = [:]
    /// When an in-flight ingest started, for the clock-based creep.
    private var ingestStarts: [Int: Date] = [:]
    /// The slice whose rescue is running, so its fraction can come from the
    /// rescue's own reported stage.
    private var rescuingSlice: (index: Int, itemID: UUID)?
    private var finishedCount = 0
    private var phase: Progress.Phase = .saving
    private var cancelled = false

    public init(
        store: ReadingListStore = .shared,
        concurrency: Int = LinkImportRunner.defaultConcurrency(),
        clock: @escaping () -> Date = Date.init,
        // `allowsInteractivePrompt: false` does two things here. It suppresses the
        // unsupported-kind modal — `.manual` is an interactive source, so a batch
        // of foreign links would otherwise stack one alert per dropped link on top
        // of the progress sheet. And it makes the ingestor's own `rescueTrigger`
        // non-interactive, so a failure is left for the debounced background sweep
        // instead of starting an inline rescue that would race phase three's
        // awaited one over the same item.
        ingest: @escaping (ReadingListItem) async -> SurfaceSupport.Decision = {
            await ReadingListIngestor.shared.ingest($0, allowsInteractivePrompt: false)
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

    /// The clock-based estimate for a slice that is mid-ingest. A page fetch and
    /// extraction report nothing until they land, and a frozen bar reads as a hung
    /// import — so an open slice eases toward the end of its ingest share.
    /// Easing, never linear: an overrunning fetch slows down instead of stalling
    /// at a wall or claiming ground it hasn't earned. Caller holds `lock`.
    private func estimate(forSlice index: Int, floor: Double) -> Double {
        guard let started = ingestStarts[index] else { return floor }
        let elapsed = max(0, clock().timeIntervalSince(started))
        let eased = 1 - exp(-elapsed / Self.expectedIngestDuration)
        return max(floor, Self.ingestShare * eased * 0.9)
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
        Self.mediaAlertSuspension?(true)
        defer { Self.mediaAlertSuspension?(false) }

        // 1. One coordinated write for the whole batch, in the file's order.
        let placements = store.insertImported(
            candidates.map {
                ReadingListStore.ImportedLink(
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

        lock.lock()
        slices = Array(repeating: 0, count: work.count)
        sliceIndexByItem = Dictionary(
            work.map { ($0.item.id, $0.slice) }, uniquingKeysWith: { first, _ in first })
        phase = work.isEmpty ? .done : .fetching
        lock.unlock()
        guard !work.isEmpty else { return summary }

        // 2. Ingest, `concurrency` at a time, in order.
        var failures: [Unit] = []
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
            summary.recoverableFailures += failures.count + (work.count - scoredUnits)
            for slice in 0..<work.count { complete(slice: slice) }
            setPhase(.done)
            return summary
        }

        // 3. The LLM rescue, one at a time, before anything is called a failure.
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
                if recovered, case .imported = fate(of: fresh) {
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
        let item: ReadingListItem
        let candidate: Candidate
    }

    private enum ItemFate: Sendable {
        case imported
        case rejected(owner: LunaApp)
        case failed
        /// The runner went away mid-flight: saved, not fetched.
        case abandoned
    }

    private func ingestOne(_ item: ReadingListItem) async -> ItemFate {
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

    /// The stored state read as an import outcome. `.needsCaptcha` counts as
    /// imported: it's a titled save the user unlocks by tapping it — a working
    /// item, not a failure to retry.
    private func fate(of item: ReadingListItem) -> ItemFate {
        switch item.state {
        case .ready, .needsCaptcha: return .imported
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
    private func awaitDownload(for item: ReadingListItem, slice: Int) async {
        guard let observe = Self.mediaDownloadProgress,
              observe(item.urlString) != nil else { return }
        let started = clock()
        let span = Self.followUpShare - Self.ingestShare
        while clock().timeIntervalSince(started) < Self.downloadWait, !isCancelled {
            guard let state = observe(item.urlString) else { return } // Finished and reaped.
            setSlice(slice, to: Self.ingestShare + span * min(1, max(0, state.fraction)))
            if state.isFinished { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.downloadPoll * 1_000_000_000))
        }
    }

    // MARK: - Slice bookkeeping

    private func sliceIndex(forItem item: ReadingListItem) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sliceIndexByItem[item.id] ?? 0
    }

    private func beginIngest(slice: Int) {
        lock.lock()
        ingestStarts[slice] = clock()
        lock.unlock()
    }

    private func beginRescue(slice: Int, itemID: UUID) {
        lock.lock()
        ingestStarts[slice] = nil
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
        ingestStarts[index] = nil
        lock.unlock()
    }

    private func complete(slice index: Int) {
        lock.lock()
        if slices.indices.contains(index), slices[index] < 1 {
            slices[index] = 1
            finishedCount += 1
        }
        ingestStarts[index] = nil
        lock.unlock()
    }

    private func setPhase(_ value: Progress.Phase) {
        lock.lock()
        phase = value
        lock.unlock()
    }
}
