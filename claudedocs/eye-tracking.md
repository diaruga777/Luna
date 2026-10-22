# Eye tracking (RSVP)

The RSVP speed reader can watch where you are looking and pause itself when
your eyes leave the word. It is off by default, opt-in per user, and lives
entirely in `LunaReaderUI`.

## The toggle

A Liquid Glass circle at the **card's top-left**, level with the deck's
read-aloud circle on the right — `EyeTrackingToggleButton`, the same
`GlassStyle.circularButtonConfiguration` circle, 38pt. Four states:

**Placement is adoption, not ownership transfer.** The reader always creates
and drives the button (state, taps); inside a card the deck ADOPTS it into
its own chrome row (`ArticleCardsViewController.syncAdoptedEyeTrackingToggle`
← `RabbitHoleReaderViewController.focusedEyeTrackingToggle`, non-nil only
while the focused layer renders RSVP — so the toggle appears in RSVP and in
no other mode). The reader's own view CANNOT seat it at the card corner: the
card's opaque title header is a sibling ABOVE the reader, and a toggle placed
level with the deck's circles from inside the reader is behind it. Hosts that
never adopt (standalone, extensions) keep the in-reader fallback: 12pt inset
below `safeAreaInsets.top + topContentInset` (`layoutEyeTrackingButton`, test
`RSVPEyeTrackingTests.testToggleClearsHostChromeStandingOverTheReader`). A
releasing host just removes the button from its superview; the reader
reclaims it on its next layout pass.

| State | Glyph | Colour | When |
| --- | --- | --- | --- |
| `.disabled` | closed eyelid | grey (`LunaColors.secondaryText`) | not watching |
| `.enabled` | `eye.fill` | grey | watching, nothing playing |
| `.active` | `eye.fill` | `GlassStyle.readingAccent` | watching a live playback |
| `.unavailable` | `eye.slash.fill` | red (`LunaColors.errorAccent`) | enabled, but ARKit has lost the reader's face/gaze |

A tap always moves between `.disabled` and whichever enabled state the current
tracking signal implies — there is no multi-way cycle.

**The closed eyelid is drawn, not named** (`ClosedEyelidGlyph`). SF Symbols has
`eye`, `eye.fill` and `eye.slash` but no closed lid, and a slashed eye reads as
"hidden content" — the wrong idea for a tracker that is simply switched off. The
glyph follows `eye.fill`'s proportions so the two states swap without appearing
to change size.

**The toggle is absent, not disabled, where the feature could never run**
(`GazeTrackingAvailability`): a device with no TrueDepth camera, or any app
extension. The share/action extensions embed the same RSVP reader but carry
their own Info.plists with no camera usage description, so asking for
authorization there would be a crash rather than a prompt.

## State

`EyeTrackingState` is a value type holding four inputs, and **exactly one of
them is durable**: `userEnabled`, mirrored into
`ReaderSettings.eyeTrackingEnabled` (App Group). The other two suppressions are
deliberately transient, which is what makes the "revert to what it was before"
rules fall out for free rather than needing bookkeeping:

- **`audioPlaybackOn`** mirrors read-aloud. Eye tracking paces a SILENT speed
  read; with speech pacing the display, gaze has nothing to say. Turning
  read-aloud on shows `.disabled`; turning it back off restores whatever
  `userEnabled` was. While it is on the button is also **non-interactive** — a
  tap could only change something invisible, and a control that lies about what
  it did is worse than one that declines.
- **`playOverridden`** is set only when the user presses play after eye
  tracking itself paused the reader — an explicit "I know, keep going". Normal
  play, even after a stale away sample, leaves tracking enabled. Playback
  resumes and the toggle drops to `.disabled`. It survives only until playback
  is deliberately stopped again (`pause(deliberate:)` — every route except a
  gaze-triggered pause), or until the process ends. Nothing is written to disk,
  so quitting the app reverts it by construction.

`isWatching == userEnabled && !playOverridden && !audioPlaybackOn`, and
`displayState` is `.disabled` unless watching, then `.active` while playing.

## Acquisition and calibration

RSVP uses coarse attention around the reading band, rather than trying to
resolve individual letters. `ARFaceGazeTracker` supplies full frames to RSVP;
closed eyes (either blink blend shape >= 0.65) and untracked faces are treated
as unavailable. Writer retains the original sample callback and its own policy.

ARKit estimates have a posture-dependent bias. At each camera-session start,
RSVP learns the median residual from 12 points clustered within 100pt of the
first point, over at least 0.2s. Movement, missing samples, or a gap over 0.15s
reset partial acquisition. The baseline stays fixed for that session: automatic
resume neither recalibrates nor adapts the baseline toward a glance away.
This remains implicit calibration: a steady fixation during initial acquisition
is assumed to be the reading position. It is not precise eye tracking, and
physical face acquisition still depends on the camera, lighting and ARKit.

If no usable baseline arrives within 1.5s, RSVP pauses and keeps watching.
Acquisition is allowed during this automatic pause, so the first usable gaze
can establish a baseline and resume instead of being stuck waiting for play.
Raw ray intersections beyond screen edges remain available for bias correction;
a ray with no forward plane intersection is `.offScreen`, never calibration data.

## When it pauses

`GazeAttentionPolicy` and `GazeAttentionMonitor` integrate time spent away:

- Within 240pt of the calibrated reading point, attention resets the allowance.
- Outside that radius, the grace falls from 0.35s to 0.18s over 420pt.
- Off-screen gaze gets 0.18s. A missing face or closed eyes gets 0.3s, so an
  ordinary blink or one bad frame does not pause reading, while turning away does.

A 100ms watchdog also handles sessions that stop producing frames. After a
0.2s frame gap it reports unavailability through the same loss policy. Startup
still gets its 1.5s acquisition allowance. A failed or silent camera session
is restarted no more than once every 2s while camera use is still authorized.
A restart retains an established attention baseline and automatic-pause latch.

## When it resumes

An automatic gaze pause keeps the same camera session running. Looking back
inside the reading radius for 0.25s resumes playback. Face loss, a blink, an
away sample, or a sample gap over 0.15s breaks that return dwell. Closed-eye
points cannot trigger a resume. The automatic-pause latch remains set through
the synchronous play callback, so resume does not stop/start the camera or
discard calibration.

Explicit pauses, a play override, disabling tracking, read-aloud, leaving the
reader, and app inactivity end the return hunt. Returning later cannot resume
an abandoned gaze pause. Manual play after a gaze pause remains the explicit
transient override described above.

## Where the gaze comes from

`ARFaceGazeTracker` runs a bare `ARSession` with `ARFaceTrackingConfiguration`
— no renderer, no view — and publishes one `GazeSample` per frame. The ray
starts at the **midpoint between the eye transforms** rather than either one:
they disagree by a few millimetres of parallax at reading distance, and the
midpoint is both steadier and closer to what a reader would call "where I'm
looking".

`GazeScreenProjection` is the geometry, kept free of ARKit so it can be
unit-tested on the simulator, where face tracking is never available:

- **Camera space.** ARKit's camera looks down −z with +y up, and
  `viewMatrix(for: .portrait)` orients that frame to the device held upright.
  The front camera has the user at negative z and the display in the z = 0
  plane. The frame is right-handed with −z pointing at the user, so **+x runs
  toward the user's view of the screen's LEFT** — the projection mirrors x
  rather than copying it.
- **Scale.** iPhone displays are laid out at ~163 UIKit points per inch and
  iPads at ~132, across every model, so points-per-metre needs no per-device
  table. The camera sits ~6mm above the top of the display.
- **Orientation.** The projection reports portrait-fixed screen points and
  `orientedScreenPoint(fromPortraitPoint:portraitSize:orientation:)` rotates
  them by hand. `UIScreen.fixedCoordinateSpace.convert(_:to:)` would do this,
  but it needs a window attached to a scene and **silently collapses every
  point to the origin without one** — working in the app and mapping the whole
  screen onto the top-left corner anywhere else.

The coordinator then subtracts the window's screen position (iPad Split View)
and lets UIKit walk the view hierarchy.

## Camera lifetime and permission

The camera runs only with eye tracking enabled, permission granted, silent
playback, the reader visible, and the app active. Playback must be running or
paused automatically while waiting for attention to return. Opening a reader,
enabling tracking while paused, or a deliberate pause leaves the camera off.
App activity (`willResignActive` / `didBecomeActive`) is independent of view
visibility, so foreground notifications cannot revive a hidden reader.

The first enabling tap requests `NSCameraUsageDescription` access. If the system
prompt is pending, RSVP pauses before requesting access. Granting access enables
the preference but leaves playback paused for a deliberate play press. Denial
leaves the setting off and offers Settings if the presenter remains visible.
The pending request disables repeat taps. A delayed callback after leaving or
manual playback changes is ignored; it cannot start playback or the camera.

`GazeTrackingPermission.statusOverride`,
`GazeTrackingAvailability.supportOverride`, the injected permission requester,
and the coordinator clock are the test seams.

## Tests

- `EyeTrackingStateTests` — the three display states and both suppressions.
- `GazeAttentionTests` — the distance curve, the allowance, discontinuities.
- `GazeCalibrationTests` — warm-up median, re-anchoring, slow re-centring.
- `GazeScreenProjectionTests` — ray/plane intersection, the x mirror, rotation.
- `RSVPAttentionLifecycleTests` — fast loss/return, blink and frame-gap continuity,
  startup acquisition while paused, silent/failed session recovery, camera churn,
  explicit lifecycle stops, and delayed permission outcomes.
- `RSVPEyeTrackingTests` — the whole feature through the reader against a stub
  gaze source: toggle states, the pause, the play-override and its reversion,
  read-aloud suppression, camera lifetime, and the systematic-bias
  calibration regression.
