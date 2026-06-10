# Pocket Trigger

Three complementary ways Clip reacts to a "pocket shot" (a dark/uniform photo):

1. **Locked-capture button (instant, primary).** `LockedCameraCapture` extension
   (`ClipCapture/`) launched from the Camera Control button / Lock Screen / Action
   button — captures and analyzes a frame on the spot. Best for "take a photo in my
   pocket → react now". (Details below.)
2. **Foreground observer (instant, app open).** `ForegroundPhotoIngestObserver` runs
   the pipeline on new photos while Clip is open.
3. **Background scan (app closed, system-woken).** `BackgroundResourceUploadExtension`
   (PhotoKit's `PHBackgroundResourceUploadExtension`, the only background hook that
   wakes the app when photos are added) scans newly-added photos with the same
   luminance/uniformity check and notifies — so a pocket photo taken with the *system*
   camera is reacted to without opening Clip. Lightweight (no CLIP/VLM) to stay under
   the extension memory ceiling. Enabled via `setUploadJobExtensionEnabled` (full photo
   access, iOS 26.1+). Caveat: Apple throttles this extension and it may not fire with
   iCloud Photos enabled — an OS limitation, so (1) and (2) are the dependable paths.

## How it works

1. The user launches Clip's capture experience **without unlocking** — via the Camera
   Control button, the Lock Screen camera control, the Action button, or Control
   Center. That control is the WidgetKit `ControlWidget` in **`ClipCaptureWidget/`**,
   bound to `ClipCameraCaptureIntent` (a `CameraCaptureIntent`).
2. iOS launches the **LockedCameraCapture extension** in **`ClipCapture/`**
   (`EXExtensionPointIdentifier = com.apple.securecapture`,
   `@main ClipCaptureExtensionBundle: LockedCameraCaptureExtension`).
3. `PocketCaptureViewController` starts the back camera, skips a few warmup frames for
   auto-exposure, then analyzes one frame. The hardware Camera Control / volume button
   (`AVCaptureEventInteraction`) forces an immediate analysis.
4. **`PocketSceneAnalyzer`** decides "pocket" purely from luminance — mean brightness
   ≤ `brightnessThreshold` (0.10) AND ≥ `darkFractionThreshold` (0.85) of sampled
   pixels near-black. No model: instant, deterministic, no memory pressure (works in
   the memory-limited extension).
5. On a pocket hit, **`ClipTriggerNotifier`** posts a local notification and records the
   event timestamp to the App Group (`group.com.hpiddy.clip`,
   key `clip.lastPocketTrigger`).

## Key files

```
ClipCapture/                       LockedCameraCapture extension (com.hpiddy.clip.capture)
  ClipCaptureExtensionBundle.swift @main LockedCameraCaptureExtension
  ClipCaptureView.swift            SwiftUI host + PocketCaptureViewController (camera, AVCaptureEventInteraction)
  PocketSceneAnalyzer.swift        luminance-based pocket detection (pure, tunable)
  ClipTriggerNotifier.swift        local notification + App Group event record
  Info.plist                       EXExtensionPointIdentifier com.apple.securecapture
  ClipCapture.entitlements         app group group.com.hpiddy.clip
ClipCaptureWidget/                 Control widget (com.hpiddy.clip.capturewidget)
  ClipCaptureWidgetBundle.swift    @main WidgetBundle
  ClipCaptureWidgetControl.swift   ControlWidget -> ControlWidgetButton(action: ClipCameraCaptureIntent)
  ClipCameraCaptureIntent.swift    CameraCaptureIntent
Clip/AppDelegate.swift             requests notification permission at launch
Clip/Info.plist                    NSSupportsLockedCameraCapture = true
```

## Device setup (one time, after installing)

1. Open Clip once and **allow notifications** (so the extension can alert).
2. Add the launch control:
   - **Control Center**: edit → add control → "Clip Pocket Capture", or
   - **Lock Screen**: customize → add the Clip control, or
   - **Action button** / **Camera Control**: Settings → assign to the Clip control / camera.
3. In the pocket: press the assigned button → Clip captures and, if it's dark, you get
   the "Pocket capture detected" notification. The hardware full-press also forces a
   capture once launched.

## Tuning

`PocketSceneAnalyzer.brightnessThreshold` / `darkFractionThreshold` / `nearBlackLuminance`
control sensitivity. Raise `brightnessThreshold` if real pocket shots aren't dark enough
to trip; lower it if bright scenes false-trigger.

## Generic action system / Shortcuts (status + options)

For now the action is a **local notification** (instant, works locked). Auto-running a
*user-defined Shortcut* on detection is constrained by iOS:
- There is no Shortcuts automation trigger for "a third-party app detected something".
- A locked capture extension cannot silently run an arbitrary user Shortcut; opening the
  app to run `shortcuts://run-shortcut?name=…` requires unlocking
  (`LockedCameraCaptureSession.openApplication`).

Practical paths to extend the action (future):
- Make the notification **time-sensitive** (entitlement `…usernotifications.time-sensitive`)
  so it pierces Focus reliably.
- Add notification **actions** (buttons) that, when tapped, open Clip and run a
  user-configured Shortcut by name via the `shortcuts://` URL — works once unlocked.
- Expose an `AppShortcutsProvider` so Clip's capture is invocable from Siri/Shortcuts.
