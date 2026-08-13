//
//  HostedShareSession.swift
//  LunaShareSurface
//

import Foundation

/// What the share/action surface receives when it is driven in-app instead
/// of from an `NSExtensionContext`.
///
/// `.url` runs the ordinary flow — append, ingest, present — over a link
/// the host supplies. `.offlineFailure` skips the fetch nobody could
/// complete and drives the real failure presentation for
/// `SaveFailureReason.offline`. With no connection there is nothing to
/// demonstrate except what a failed save actually looks like, and showing
/// the genuine error is more honest than mocking a success.
public enum HostedShareInput {
    case url(URL)
    case offlineFailure(URL)
}

/// What the in-app host of a `HostedShareSession` is told as the real surface
/// works: everything the onboarding save lesson needs to pace itself against
/// actual progress rather than a fixed hold.
@MainActor
public protocol HostedShareSessionDelegate: AnyObject {
    /// The save row the hosted flow created, reported so the host can
    /// mark it as its temporary save and take it back out afterwards.
    func hostedShareSessionDidAppendRow(_ itemID: UUID)

    /// The surface has something final on screen: a reader, a saved-media
    /// screen, a price editor, an error, or a completed request. The host
    /// waits for this instead of counting out a fixed hold, so the sheet
    /// stays up for exactly as long as the real work took.
    func hostedShareSessionReachedTerminal()

    /// The local file a downloaded video landed in. The host plays it,
    /// muted and looping, over the sheet: the point of the media lesson is
    /// that the thing the user saved is now theirs, and a still poster
    /// does not say that.
    func hostedShareSession(mediaFileReadyAt fileURL: URL)
}

/// A kind screen that can play its own beat again from what it already
/// has. Installed on `HostedShareSession.beatReplayer` by the screen
/// itself.
@MainActor
public protocol HostedShareBeatReplaying: AnyObject {
    func replayHostedShareBeat()
}

/// The rendezvous between an in-app host of `ShareViewController` and the
/// kind modules the surface presents through.
///
/// The onboarding save lesson embeds the real extension surface in a mock
/// sheet. Two things about a rehearsal differ from an extension launch,
/// and neither is something `ShareSurfaceDriver` or a kind presenter
/// should have to know about the caller to get right:
///
/// - a download that finished while the sheet was still sliding up has
///   nothing to show, so the media screen would jump straight to a
///   finished file and the lesson would never demonstrate that a fetch
///   happened at all;
/// - the demonstration loops, so an artifact whose owner deletes it on
///   teardown (a downloaded preview file) has to survive between passes,
///   or every replay costs another download.
///
/// So the host publishes one session on `current` for the duration of the
/// lesson, and the kind modules consult it. It stays nil in a real
/// extension, where every one of these behaviors is exactly the unchanged
/// default.
@MainActor
public final class HostedShareSession {

    /// The live session, or nil in a real extension process.
    ///
    /// Weak on purpose: the host owns the session for exactly as long as
    /// it owns the lesson, so tying `current` to that ownership means a
    /// host that goes away without a tidy shutdown cannot leave a stale
    /// session behind for the next flow to obey. This also means the
    /// assignment must go to a stored session — `current =
    /// HostedShareSession()` would already be nil on the next line.
    public static weak var current: HostedShareSession?

    public init() {}

    // MARK: - Reveal

    /// When the sheet carrying the surface finished revealing it. Nothing
    /// the user is meant to see may resolve before this.
    public private(set) var revealDate: Date?

    public func markRevealed() {
        guard revealDate == nil else { return }
        revealDate = Date()
    }

    /// Rewinds the reveal for another pass. The onboarding demonstration
    /// loops, and each pass is a fresh opening of the sheet, so each pass
    /// gets its own minimum indication.
    public func beginReveal() {
        revealDate = nil
    }

    /// The least time a download indication stays up after the reveal. A
    /// preloaded file is already on disk by the time the sheet opens;
    /// without a floor, the progress bar would appear and vanish inside
    /// one frame.
    public var minimumDownloadIndication: TimeInterval = 0.3

    /// The earliest a download indication may give way to its result, or nil
    /// while the sheet is still opening (nothing may resolve yet).
    public var earliestDownloadResolution: Date? {
        revealDate?.addingTimeInterval(minimumDownloadIndication)
    }

    // MARK: - Media

    /// True while the media kind still has something to put on screen: a
    /// download in flight, or a ready video whose playback has not run
    /// yet. The host keeps the sheet open until this clears, so the
    /// lesson never dismisses mid-fetch.
    public var awaitsMediaPlayback = false

    // MARK: - Reporting back to the host

    /// The onboarding controller hosting this session, held weakly since
    /// it owns the session. Nil in the share/action extensions, where
    /// nothing is hosted and every report below is simply not made.
    public weak var delegate: (any HostedShareSessionDelegate)?

    /// Set by whichever kind screen can play its own beat again from what
    /// it already has: the media screen re-running its download
    /// indication and its playback off the retained file. The host calls
    /// `replayBeat()` on each pass of the looping demonstration, so a
    /// second showing costs no network at all. Kind-neutral by
    /// construction, since the host never learns which screen answered.
    /// Weak, because the screen is owned by the view hierarchy, not by the
    /// session.
    public weak var beatReplayer: (any HostedShareBeatReplaying)?

    public func replayBeat() {
        beatReplayer?.replayHostedShareBeat()
    }

    // MARK: - Retained artifacts

    /// Things whose lifetime must outlast the flow that produced them: a
    /// downloaded preview file the next demo pass shows again without
    /// refetching. Read-only, so every retention pairs with a way to let
    /// it go.
    public private(set) var retainedArtifacts: [Any] = []

    private var releases: [() -> Void] = []

    /// Holds `artifact` for the session's lifetime. `release` runs at
    /// `releaseArtifacts()`, on teardown or a cancelled lesson, and is
    /// where the on-disk file actually goes.
    public func retain(_ artifact: Any, release: @escaping () -> Void) {
        retainedArtifacts.append(artifact)
        releases.append(release)
    }

    /// Lets every retained artifact go, once. Kind-neutral, so the host
    /// can end the lesson without naming a media type it does not link.
    public func releaseArtifacts() {
        let pending = releases
        releases = []
        retainedArtifacts = []
        for release in pending { release() }
    }
}
