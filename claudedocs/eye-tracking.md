# Eye tracking (RSVP)

The RSVP speed reader can watch where you are looking and pause itself when
your eyes leave the word. It is off by default, opt-in per user, and lives
entirely in `LunaReaderUI`.

## The toggle

A Liquid Glass circle in the reader's **top-left** corner —
`EyeTrackingToggleButton`, the same `GlassStyle.circularButtonConfiguration`
circle as the reader chrome's read-aloud button, 38pt. Four states:

Its corner is the READER's, not the card's: the 12pt inset is measured from
`safeAreaInsets.top + topContentInset`, and inside a Reader card that inset is
the opaque title header standing over the top of the speed reader. That header
is a sibling ABOVE the reader's view, so a toggle placed level with the deck's
own circles is not crowded by it — it is behind it, and the control disappears
from RSVP altogether (`layoutEyeTrackingButton`, test
`RSVPEyeTrackingTests.testToggleClearsHostChromeStandingOverTheReader`).

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

## Calibration — the estimate is judged relative, never absolute

ARKit's `lookAtPoint` carries a systematic per-user, per-posture bias —
commonly several degrees, worst vertically — that easily exceeds the focus
radius. Uncalibrated, that meant a fixated reader drained the near tolerance
continuously and was paused ~1.8s into every playback. `GazeCalibration`
(owned by the coordinator) removes it implicitly, with no calibration UI:

- **Warm-up.** Every playback start opens a warm-up: the eyes just left the
  play button, the strongest ground truth the feature ever gets. The first 45
  playing samples' residuals (raw point − focal point) are collected and their
  per-axis MEDIAN becomes the offset subtracted from every later sample.
  Median, not mean — a glance away during warm-up is an outlier to survive.
  Until the first offset exists, point samples are learned from but never
  judged (`.offScreen` — no plane intersection — still is: it needs no
  calibration). A re-anchor keeps the old offset in force while collecting.
- **Re-centring.** Samples whose CALIBRATED point sits inside the focus radius
  nudge the offset toward their residual (1%/frame) — slow drift correction
  for settling posture that can never chase a genuine look-away.
- **Lifetime.** The offset dies with the tracker session (`syncTracker` stop)
  and is re-anchored at every playback start; a focal jump (scrub/skip) drops
  a warm-up's partial residuals but leaves an established offset alone — bias
  is a property of the estimator, not of the word's position.
- **Stated trade-off:** warm-up trusts playback as ground truth. Starting
  playback and immediately looking away for the whole warm-up anchors the
  offset wrongly until the next play press; the alternative — trusting
  ARKit's absolute accuracy — paused every reader every time.

Because only the calibrated point says where the reader is actually looking,
the tracker emits every plane intersection as `.point` even beyond the display
edges (a bias big enough to push a fixated gaze off-screen is exactly what
calibration rescues); the coordinator classifies on/off-display AFTER
subtracting the offset.

## Debug overlay (hidden diagnostics)

`RSVPGazeDebugOverlay` draws the raw estimate (small grey dot), the calibrated
estimate (accent dot), the focus-radius circle and a numeric readout (raw/cal
deltas, learned offset, away %) over the reader — enough to tell a systematic
projection bias from noise on a real device, which is the one thing the
simulator suite can never see (`GazeScreenProjectionTests` validate the maths
against its own convention; only hardware validates the convention). Off by
default, per-user (`ReaderSettings.gazeDebugOverlayEnabled`), and toggled ONLY
from the hidden Diagnostics screen (five taps anywhere on Settings). The
reader checks the flag on each appearance (`syncGazeDebugOverlay`), so
flipping it needs no relaunch. The overlay is touch-transparent and installed
above the reader's chrome.

## When it pauses

`GazeAttentionPolicy` turns distance-from-the-focal-word into a dwell
tolerance; `GazeAttentionMonitor` integrates elapsed time against it.

- Inside `focusRadius` (240pt) nothing is timed at all. Generous on purpose:
  gaze from a front camera is good to a few centimetres at arm's length, not to
  the letter, and RSVP's context lanes are legitimately part of the reading
  surface.
- Beyond it the tolerance falls linearly from `nearTolerance` (1.8s) to
  `farTolerance` (0.7s) over `falloffDistance` (420pt) — so the delay really
  does depend on how far the gaze travelled.
- A confidently off-screen gaze skips the curve and takes `farTolerance`
  directly. A lost face is uncertainty, never evidence that the reader looked
  away: tracking enters `.unavailable`, clears its dwell timer, shows a red
  slashed eye, and has no effect until ARKit supplies a usable gaze again.

The monitor **integrates rather than timing one excursion**, so a gaze that
drifts outward — 300pt away for a moment, then off the phone — spends its
allowance at the rate each instant deserves instead of being judged by wherever
it happened to be when a fixed timer expired. Any sample back on the word
resets the allowance in full.

A gap between samples longer than `maximumSampleGap` (0.5s) is a
**discontinuity** — a suspended app, a pre-empted camera — and restarts the
excursion. It is not clamped: any clamp at or above `farTolerance` would pause
the reader the instant the session resumed.

`resetAllowance()` forgets the time spent but **not** `isAway`. That
distinction is load-bearing: a gaze pause resets the clock while the reader's
eyes have not moved back, and `isAway` is exactly what a following play press
consults to recognise itself as an override.

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

## Camera lifetime

`RSVPGazeCoordinator.syncTracker` runs the session exactly while the feature is
watching AND the reader is on screen AND camera access is granted — never
merely because the reader is open, and never once the toggle is off or
read-aloud has taken over. It stops on `viewWillDisappear` and on
`didEnterBackground`.

The session keeps running **while paused**, not only while playing. That is
what makes the play-override honest: the only way to know the reader is looking
away at the moment they press play is to still be looking.

## Permission

Eye tracking is front-camera capture, so the permission is
`NSCameraUsageDescription`:

> Luna tracks your eyes to pause playback automatically when you look away.

It is requested at the ONE moment it is about — **the first tap that turns the
toggle on** — not at launch and not when the reader opens. A refusal leaves the
toggle off and offers Settings. `GazeTrackingPermission.statusOverride` and
`GazeTrackingAvailability.supportOverride` are the test seams.

## Tests

- `EyeTrackingStateTests` — the three display states and both suppressions.
- `GazeAttentionTests` — the distance curve, the allowance, discontinuities.
- `GazeCalibrationTests` — warm-up median, re-anchoring, slow re-centring.
- `GazeScreenProjectionTests` — ray/plane intersection, the x mirror, rotation.
- `RSVPEyeTrackingTests` — the whole feature through the reader against a stub
  gaze source: toggle states, the pause, the play-override and its reversion,
  read-aloud suppression, camera lifetime, the systematic-bias calibration
  regression, and the diagnostics overlay's presence rules.
