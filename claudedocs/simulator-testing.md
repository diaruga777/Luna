# Simulator Testing & Sim-Only Hooks

The Blitz iPhone automation harness (`blitz-iphone` MCP: `describe_screen`,
`device_action` tap/swipe/input-text, `get_screenshot`) drives the iOS-27 sim
(UDID `AA3C058C-9671-4448-9F53-510DED654FE5`). **Always test features in the
simulator before shipping.**

## Known harness limitations

- **No long-press / context menu**: `device_action` tap-with-`duration` does NOT
  synthesize a `UIContextMenuInteraction` long-press.
- **No drag / swipe-to-action**: pan-driven gestures (card swipes, reorder lift,
  interactive dismissals) aren't reliably synthesizable.
- **Link glyphs in `UITextView` aren't tappable** and don't fire `primaryActionFor`.
- **Bottom-edge taps** (≈ home-indicator zone) are often swallowed.
- **Tap coords** = `describe_screen` AX point × ~0.971 on this sim.
- `describe_after` returns the AX tree at a delay (use it to catch transient UI like
  toasts that a later separate `get_screenshot` would miss); it does NOT return an
  image — read the returned `screen_description` for labels.

## Rule: add sim-only hooks for gestures the harness can't do

When a feature relies on a gesture the harness can't perform, **add an alternative
tap target / button behind a simulator check** so you can test it yourself, then
verify via the harness. NEVER ship these on device.

- Gate every hook with **`if AppEnvironment.isSimulator`** (`Luna/AppEnvironment.swift`,
  `#if targetEnvironment(simulator)`).
- Give the hook an `accessibilityLabel` so `describe_screen` can find it.
- Prefer reusing the real code path (e.g. set a `UIButton.menu` to the same `UIMenu`
  with `showsMenuAsPrimaryAction = true`, so the sim button opens the exact context
  menu the long-press would).

### Existing hooks

- **Reading list row context menu** — `ReadingListItemCell.setSimulatorMenu(_:)` adds
  a small bottom-left "Row actions" button (`ellipsis.circle`) whose `.menu` is the
  same `ReadingListViewController.rowMenu(for:at:)`; a plain tap opens it. Wired in
  `cellForRowAt` only when `AppEnvironment.isSimulator`.
- **Catch-up cards** — the swipe actions also exist as the real bottom Bump / Mark
  Read buttons, so card actions are testable by tapping those (no extra hook needed).
  A **"Sim Swipe"** button (`CatchUpViewController.addSimulatorSwipeHookIfNeeded`)
  holds the current card at a partial rotation (`CatchUpCardView.simulatorHoldSwipe`)
  so the rotated state — e.g. that the glass header doesn't balloon — is inspectable
  without a drag gesture.
- **Inline reader split** — `ScrollReaderViewController.addSimulatorSplitHooksIfNeeded`
  adds **"Split High"/"Split Low"** buttons that call `openSplit` at a high/low screen
  fraction, since the harness can't tap an exact inline link. Use these to verify the
  open animation, header tucking, and the cut landing on the tapped line.
- **RabbitHole dive/pop** — `RabbitHoleReaderViewController.addSimulatorDiveHooksIfNeeded`
  adds **"Sim Dive"/"Sim Pop"** buttons driving the same `pushLayer`/`popToLayer` paths a
  link tap and the header back use, since text-view link glyphs aren't tappable. Use them
  to verify the dive/pop wipe (content pixelates, header/lip chrome fades).

## Harness gotchas learned the hard way

- **Software keyboard**: sims often have "Connect Hardware Keyboard" ON, so no software
  keyboard ever appears. Fix: `defaults write com.apple.iphonesimulator
  ConnectHardwareKeyboard -bool false` (plus the per-device `DevicePreferences` entry),
  then **shut down and re-boot the device** — a Simulator.app restart alone is not
  enough. First keyboard use also shows the swipe-typing intro panel instead of the
  keyboard; its Continue button sits in the swallowed bottom-edge zone.
- **Touch injection can die wholesale** (every tap silently ignored while screenshots
  and `simctl openurl` still work), e.g. after Simulator.app restarts. Symptoms: AX
  trees go stale (describe_screen shows a previous screen). App relaunches don't help;
  the blitz-iphone MCP server needs a restart.
- **App-group defaults**: `simctl spawn <udid> defaults write group.com.hsanabria.luna …`
  writes the wrong domain. Write by container path instead:
  `GC=$(simctl get_app_container <udid> <bundle> groups | grep group… | awk '{print $2}')`
  then `defaults write "$GC/Library/Preferences/group.com.hsanabria.luna" key -bool true`.
