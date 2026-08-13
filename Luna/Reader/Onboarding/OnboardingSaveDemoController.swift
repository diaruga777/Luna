//
//  OnboardingSaveDemoController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaShareSurface
import LunaStorage
import UIKit

enum OnboardingSaveDemoTiming {
    /// How long a downloaded video plays over the sheet before the lesson moves
    /// on. Long enough to read as playback rather than a poster that twitched.
    static let videoPlaybackDuration: TimeInterval = 2.0
    /// The fade in and out of that overlay.
    static let videoFadeDuration: TimeInterval = 0.22
    /// How long the sheet holds on a finished screen — a reader, a price editor,
    /// an error — before sliding away. The same beat the hand-drawn mock used to
    /// hold for, now spent on the real thing.
    static var terminalHoldDuration: TimeInterval {
        OnboardingShortcutRunTiming.extensionSheetHoldDuration
    }
    /// How often the wait re-checks whether the media kind still owes the host
    /// something. There is deliberately no ceiling on top of it: the surface's own
    /// 15s attachment watchdog and the pipeline's 28s ingest budget are the real
    /// backstops, and inventing a shorter one here would cut a slow save off
    /// mid-work and call it a demonstration.
    static let mediaSettleInterval: TimeInterval = 0.15
}

/// THE SAVE LESSON'S ENGINE: it runs a real save through the real share surface
/// and shows you what happened.
///
/// The lesson used to be a drawing — a fake extension sheet holding a bundled
/// article for a fixed second. Everything here exists to make it the actual
/// thing instead:
///
/// - it resolves a real link (`OnboardingSaveDemoLink`): this app's live Save of
///   the Week when there is one, else the bundled practice link, else — offline —
///   the genuine failure state;
/// - it starts the work EARLY, and the UI late. The real surface is loaded the
///   moment the user taps into the lesson — DETACHED, in no view hierarchy —
///   so the fetch overlaps the conversation animating in front of it; the
///   sheet and the surface's view are mounted only when `present` needs them.
///   The split is deliberate beyond taste: the press wave opens by
///   screen-snapshotting the replica's hierarchy, and a hidden live WKWebView
///   sitting inside it is exactly the thing that can make that snapshot fail;
/// - it waits for the surface's OWN terminal state instead of a timer, so the
///   sheet is up for exactly as long as the real work took;
/// - it takes the save back out. A rehearsal must leave the deck exactly as
///   empty as the user left it, so the row it creates is marked as this app's
///   temporary save and deleted after every pass — including its media companion
///   state, which the shared shell reaches through the kind-neutral
///   `ShareMediaSideEffects` rather than by naming a module three of the four
///   apps do not link.
@MainActor
final class OnboardingSaveDemoController {

    /// The link this pass rehearses with, resolved once at construction: the
    /// conversation's bubble, the real share sheet, and the hosted surface all
    /// have to agree about what is being saved.
    let link: OnboardingSaveDemoLink

    private let onboardingStore: AppOnboardingStore
    private let contentStore: SavesStore
    private let session = HostedShareSession()
    private weak var host: UIViewController?
    /// Internal read for the lesson tests: loaded at `start`, mounted at
    /// `present`.
    private(set) var surface: ShareViewController?
    private var sheet: OnboardingHostedShareSheetView?
    private var playback: VideoCardContentViewController?
    private var pendingVideoFileURL: URL?
    /// The row the hosted flow created, so cleanup deletes THIS save and not
    /// whatever else happens to sit at the same URL.
    private var temporarySaveID: UUID?
    private var didStart = false
    private var didReachTerminal = false
    /// Guards every callback and every scheduled step against a pass that has
    /// already been cancelled — the demonstration loops, and a stale completion
    /// firing over a newer pass is how a mock sheet ends up on screen with
    /// nothing behind it.
    private var presentationGeneration = 0
    private var waitCompletion: (() -> Void)?

    init(
        link: OnboardingSaveDemoLink,
        onboardingStore: AppOnboardingStore = .shared,
        contentStore: SavesStore = .shared
    ) {
        self.link = link
        self.onboardingStore = onboardingStore
        self.contentStore = contentStore
    }

    // MARK: - Lifecycle

    /// Starts the real surface WORKING — detached, in no view hierarchy.
    /// Idempotent: both entries into the lesson (first run and the settings
    /// replay) call it, and the demonstration loop calls it again on every pass.
    /// Nothing joins `host`'s view tree here; `present` mounts the UI when the
    /// sheet is actually about to slide up.
    func start(in host: UIViewController) {
        guard !didStart else { return }
        didStart = true
        self.host = host

        // The media kind, if this app has one, can begin resolving and
        // downloading before anything is on screen at all.
        if !link.isOffline {
            ShareMediaSideEffects.preloadDownload(forURLString: link.urlString)
        }

        HostedShareSession.current = session
        session.delegate = self

        let surface = ShareViewController(
            hosted: hostedInput,
            onFinish: { [weak self] in self?.surfaceDidReachTerminal() })
        self.surface = surface
        // Force the surface's own load: `viewDidLoad` — which is where the save
        // begins — runs NOW, on a view that hangs nowhere yet.
        surface.view.frame = host.view.bounds
        surface.view.layoutIfNeeded()
    }

    /// Builds the sheet and mounts the working surface into `host` — the UI
    /// half of `start`, deferred to first presentation and reused by every
    /// replay after it.
    private func mountUIIfNeeded() -> OnboardingHostedShareSheetView? {
        if let sheet { return sheet }
        guard let host, let surface else { return nil }
        let sheet = OnboardingHostedShareSheetView(frame: host.view.bounds)
        sheet.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sheet.hideImmediately()
        host.view.addSubview(sheet)
        self.sheet = sheet

        host.addChild(surface)
        surface.view.frame = sheet.content.bounds
        surface.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sheet.content.addSubview(surface.view)
        surface.didMove(toParent: host)
        return sheet
    }

    private var hostedInput: HostedShareInput {
        guard let url = URL(string: link.urlString) else {
            // Unreachable in practice (every practice link and every weekly entry
            // is a valid absolute URL), and there is no honest save to show
            // without one — so show the failure, which is at least true.
            return .offlineFailure(
                URL(string: ShareSetupPractice.lunaURLString)!)
        }
        return link.isOffline ? .offlineFailure(url) : .url(url)
    }

    /// Slides the sheet up, then waits for the surface's own resolution — a
    /// finished request, a screen it presented, an error, or a video it
    /// downloaded and played. `completion` runs when the lesson may move on.
    func present(completion: @escaping () -> Void) {
        guard let sheet = mountUIIfNeeded() else {
            completion()
            return
        }
        presentationGeneration += 1
        let generation = presentationGeneration
        waitCompletion = completion
        session.beginReveal()
        sheet.frame = host?.view.bounds ?? sheet.frame
        // Every pass after the first shows the same result again from what the
        // surface already holds: no refetch, no second download.
        if didReachTerminal { session.replayBeat() }
        sheet.present { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            self.session.markRevealed()
            self.settleOrFinishWait(generation: generation)
        }
    }

    /// Slides the sheet away and takes this pass's save back out of the store.
    func dismiss(completion: @escaping () -> Void) {
        presentationGeneration += 1
        cancelPlayback()
        guard let sheet else {
            removeTemporarySave()
            completion()
            return
        }
        sheet.dismiss { [weak self] in
            self?.removeTemporarySave()
            completion()
        }
    }

    /// Ends the pass immediately — an external hop, a cancelled replay, a paste
    /// handing off to the real app. The surface and its cached result survive, so
    /// re-entering the lesson costs nothing; only what is on screen and what is in
    /// the store go away.
    func abortPresentation() {
        presentationGeneration += 1
        waitCompletion = nil
        cancelPlayback()
        sheet?.hideImmediately()
        removeTemporarySave()
    }

    /// The lesson is over. Everything goes, including the downloaded file the
    /// replays were reusing.
    func tearDown() {
        abortPresentation()
        didStart = false
        surface?.willMove(toParent: nil)
        surface?.view.removeFromSuperview()
        surface?.removeFromParent()
        surface = nil
        sheet?.removeFromSuperview()
        sheet = nil
        session.delegate = nil
        session.beatReplayer = nil
        session.releaseArtifacts()
        ShareMediaSideEffects.deleteSavedContents(forURLString: link.urlString)
        if HostedShareSession.current === session {
            HostedShareSession.current = nil
        }
    }

    // MARK: - Waiting for the real resolution

    private func surfaceDidReachTerminal() {
        didReachTerminal = true
        settleOrFinishWait(generation: presentationGeneration)
    }

    /// The one place the pass decides it is done. Three conditions, in order:
    /// the sheet has to be open (nothing may resolve behind a closed sheet), the
    /// surface has to have reached its own terminal state, and the media kind must
    /// have nothing further to put on screen.
    private func settleOrFinishWait(generation: Int) {
        guard generation == presentationGeneration,
              waitCompletion != nil,
              session.revealDate != nil,
              didReachTerminal
        else { return }

        if let fileURL = pendingVideoFileURL {
            pendingVideoFileURL = nil
            playVideo(at: fileURL, generation: generation)
            return
        }
        guard !session.awaitsMediaPlayback else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(
                    OnboardingSaveDemoTiming.mediaSettleInterval)
            ) { [weak self] in
                self?.settleOrFinishWait(generation: generation)
            }
            return
        }
        afterDelay(
            OnboardingSaveDemoTiming.terminalHoldDuration,
            generation: generation
        ) { [weak self] in
            self?.finishWait(generation: generation)
        }
    }

    private func finishWait(generation: Int) {
        guard generation == presentationGeneration,
              let completion = waitCompletion
        else { return }
        waitCompletion = nil
        completion()
    }

    // MARK: - Playback

    /// The saved video, playing over the sheet: muted, looping, no chrome. A
    /// still poster says "a file arrived"; this says "it is yours now".
    private func playVideo(at fileURL: URL, generation: Int) {
        guard let host, let sheet else {
            finishWait(generation: generation)
            return
        }
        cancelPlayback()
        let player = VideoCardContentViewController(fileURL: fileURL)
        playback = player
        host.addChild(player)
        player.view.frame = sheet.convert(sheet.cardFrame, to: host.view)
        player.view.backgroundColor = .black
        player.view.isUserInteractionEnabled = false
        player.view.alpha = 0
        host.view.addSubview(player.view)
        player.didMove(toParent: host)
        player.setMuted(true)
        player.setPlaying(true)
        UIView.animate(
            withDuration: OnboardingSaveDemoTiming.videoFadeDuration
        ) {
            player.view.alpha = 1
        }
        afterDelay(
            OnboardingSaveDemoTiming.videoPlaybackDuration,
            generation: generation
        ) { [weak self] in
            guard let self else { return }
            self.session.awaitsMediaPlayback = false
            UIView.animate(
                withDuration: OnboardingSaveDemoTiming.videoFadeDuration,
                animations: { player.view.alpha = 0 }
            ) { _ in
                self.cancelPlayback()
                self.settleOrFinishWait(generation: generation)
            }
        }
    }

    private func cancelPlayback() {
        guard let playback else { return }
        self.playback = nil
        playback.setPlaying(false)
        playback.willMove(toParent: nil)
        playback.view.removeFromSuperview()
        playback.removeFromParent()
    }

    // MARK: - The rehearsal's own save

    /// Marks the row the hosted flow just created as this app's temporary save.
    /// The marker is what keeps the lesson's save from answering the first run
    /// (`AppOnboardingStore.markCompletedIfSavedSinceOnboardingStart` excludes
    /// it) even if a launch lands between the save and its deletion.
    private func claimTemporarySave(_ id: UUID) {
        temporarySaveID = id
        onboardingStore.recordTemporarySave(identifier: id)
    }

    /// Undoes the rehearsal. The save row (with every file it owns), its
    /// failure record, and the media kind's own bookkeeping — then the marker
    /// itself, because there is nothing left for it to name.
    private func removeTemporarySave() {
        // By id, not by URL: the pipeline can repoint the row it created to a
        // resolved publisher URL, and another save may legitimately sit at the one
        // the lesson started from.
        let id = temporarySaveID
            ?? onboardingStore.temporarySaveIdentifier
            ?? contentStore.item(forURLString: link.urlString)?.id
        if let id {
            SaveFailureStore.shared.clear(id)
            if let item = contentStore.item(withID: id) {
                contentStore.delete(item)
            }
        }
        ShareMediaSideEffects.deleteSavedContents(forURLString: link.urlString)
        temporarySaveID = nil
        onboardingStore.clearTemporarySaveIdentifier()
    }

    private func afterDelay(
        _ delay: TimeInterval,
        generation: Int,
        _ work: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(delay)
        ) { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            work()
        }
    }
}

/// What the real surface reports back as the rehearsal runs. The session holds
/// this weakly; `tearDown` clears it so a stopped lesson hears nothing more.
extension OnboardingSaveDemoController: HostedShareSessionDelegate {
    func hostedShareSessionDidAppendRow(_ itemID: UUID) {
        claimTemporarySave(itemID)
    }

    func hostedShareSessionReachedTerminal() {
        surfaceDidReachTerminal()
    }

    func hostedShareSession(mediaFileReadyAt fileURL: URL) {
        pendingVideoFileURL = fileURL
    }
}
