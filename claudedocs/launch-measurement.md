# Cold-launch measurement

`scripts/measure_launch.sh` reports how long an app takes to launch on the
physical iPhone 11. Use it to hold a refactor to a launch-time budget — move
shared code into a dynamic framework, measure again, compare.

```sh
scripts/measure_launch.sh LunaReader --label baseline
scripts/measure_launch.sh Luna       --label baseline
scripts/measure_launch.sh Luna       --label framework   # after the change
```

Flags: `--device <udid>` picks another device (default is the iPhone 11,
`5431A3BA-3404-59CA-A867-D94B0C3ED36C`, reachable over the local network);
`--label <name>` names the output file. Only `Luna` and `LunaReader` are wired.

## What it runs

The `LaunchPerf` test plan, in **Release**:

```sh
xcodebuild test -project Luna.xcodeproj -scheme <app> -testPlan LaunchPerf \
  -only-testing:<app>LaunchTests -destination "platform=iOS,id=<udid>" \
  -configuration Release -derivedDataPath <dd> -resultBundlePath <result> \
  -allowProvisioningUpdates DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO
```

Release, not Debug. A Debug build links the debug-dylib arrangement and compiles
at `-Onone`, so its dyld and first-frame cost do not describe the shipping
binary — and dyld cost is what this measurement watches.

Never add `CODE_SIGNING_ALLOWED=NO`. It strips the app-group entitlement, so the
app dies at launch on its first container access. For physical-device signing,
set your own `DEVELOPMENT_TEAM` in the ignored `Config/Local.xcconfig`; the
phone must be unlocked and trusted.

The script terminates any running copy of the app first, so the first iteration
is a cold start like the rest.

## The two metrics

`LunaLaunchTests/LaunchPerformanceTests` (one file, compiled into both UI-test
targets) measures ten iterations of each:

- `testLaunchPerformance` — `XCTApplicationLaunchMetric()`. Process start to the
  first frame.
- `testLaunchToResponsivePerformance` — `XCTApplicationLaunchMetric(waitUntilResponsive: true)`.
  Process start to the app answering the accessibility server. This is closer to
  what a user feels, and it covers first-screen work the first-frame number hides.

XCTest runs one extra warm-up iteration per metric and drops it, so ten values
are reported.

## Reading the output

Per metric the script prints the iteration count, mean, standard deviation (with
its size relative to the mean), median, min, max, and every iteration value,
then writes the same numbers to
`/private/tmp/claude-501/-Users-hsp-Desktop-Lune/0ce06c9e-b7f9-484a-9547-b90401fbae15/scratchpad/launch/<label>-<app>.json`
plus a timestamped copy, so a second run under one label keeps the first.

Read the **mean**, and read the **standard deviation** before you believe it. On
a phone that also runs everything else Apple ships, single launches vary. Two
runs of the same unchanged binary are the scale of the noise: measure the
baseline twice and treat any difference smaller than that spread as no
difference. The working bar for a refactor is 5% on the mean.

A rising standard deviation with a flat mean is usually thermal or background
load on the phone, not the code. Re-run rather than reason about it.

## Measured noise floor on the iPhone 11 (Sep 2026)

Two runs of `Luna` and three of `LunaReader`, same unchanged binary:

| app | metric | run-to-run spread of the mean | spread of the median |
| --- | --- | --- | --- |
| `Luna` | first frame | 1.7% | 1.2% |
| `Luna` | responsive | 0.3% | 0.2% |
| `LunaReader` | first frame | 10.9% | 6.2% |
| `LunaReader` | responsive | 7.4% | 3.5% |

`Luna` sits far inside a 5% bar, so a 5% change in its mean is a real change.

`LunaReader` does not. Its three means rose 2393 → 2480 → 2667 ms across
consecutive runs, so a single before/after pair cannot resolve 5% on that app.
For `LunaReader`, interleave the before and after runs (before, after, before,
after) and compare medians, or take three runs of each side. Its standard
deviation reaches 12% within one run, which is where the drift comes from.


## The plan and the targets

Two UI-test targets, `LunaLaunchTests` (`TEST_TARGET_NAME` `Luna`) and
`LunaReaderLaunchTests` (`TEST_TARGET_NAME` `LunaReader`), cloned from
`LunaWriterUITests`. Both compile the single file in `LunaLaunchTests/`.

`LaunchPerf.xctestplan` holds both, and is attached to the existing `Luna` and
`LunaReader` schemes — no sixth scheme. Attaching it moved the `Luna` scheme onto
test plans, so its **default** plan `Luna.xctestplan` runs exactly what the old
inline list ran: `LunaTests`. `scripts/run_tests.sh` passes no `-testPlan` and so
still runs the unit suite. `LunaReader` ran no tests before, so `LaunchPerf` is
its only plan.

Re-run `ruby scripts/hide_generated_schemes.rb` after touching these targets.

## Startup work ordering

The foreground launch path installs only the kind/card presenters, onboarding
state, reader settings, the article audio observer/remote-command seam, and the
background-task registrations that iOS requires before launch returns. Finished
articles are archived before selecting the first card. Cached saves render directly
in the actual root hierarchy.

`AppLaunchServices` starts asynchronous foreground installation after the first
root frame. Bridge registration and UI witnesses stay on main; plugin manifest
reads, legacy secret migration, JavaScript VM construction and plugin evaluation
run on a worker. The complete platform is published together on main. The window
never installs services from `sendEvent`: cached cards, scrolling, the scrubber
and Settings remain available while plugins load. Settings refreshes its category
list when installation finishes.

Deep links, background URLSession callbacks, maintenance and mini-player setup
queue with `whenReady`; asynchronous intents and mail/price tasks use
`waitUntilReady()`. In-app save, reader save-link, transcription and onboarding
paste actions also await readiness inside their existing async operations.
Settings opens immediately; only its plugin destination waits for the platform. Repeated triggers share one installation. Bluetooth restoration
and deterministic stages retain the synchronous path before foreground loading
starts, so restored central managers exist before `didFinishLaunching` returns.

Save retries, mail import, indexing, retention sweeps, weekly refresh and price
refresh start once after reveal AND service readiness. The first scene foreground
callback does not duplicate launch refresh. Background-only wakes retain the
one-second scene-connection fallback. Staged launches suppress maintenance.

Regression coverage holds the real plugin execution queue during an asynchronous
install and proves main-actor work can continue, then checks the loaded platform.
A separate gated-install test checks readiness waiters, ordering and idempotence.
The previous synchronous post-frame setup took about 80 ms on an iPhone 17 Pro /
iOS 26.2 simulator with a small article fixture; this does not reproduce the
reported populated-phone delay, and first-frame timing alone cannot verify touch
responsiveness.

Normal launches draw the root directly, with no app-owned splash overlay, hold,
or crossfade. The empty util card shows its headline and controls immediately;
the animated intro remains available to explicit visual stages. Safari hand-offs
retain their bounded splash hold. The carousel creates its playback-speed pill
only when a playable card needs it.

Bundled plugin manifests remain cached per catalog, and speech synthesis still
starts only when audio is requested. Audio observers remain installed before
reader construction so populated decks retain their read-aloud behavior.

Current saves databases (schema 20+) open without taking the schema writer lock
or repeating schema/search-index setup. Legacy layouts migrate once before using
that fast path. With media retention set to keep forever (the default), the deck
also skips the retention transaction and its file-reaper pass entirely.
The finished-article archive pass first checks its partial index with a WAL read;
only actual pending completions take the write lock, then re-read under that lock.

Validation: 62 focused tests pass (startup ordering/idempotence, plugin boot,
audio playback, speed controls and launch geometry). A broader selection also
found existing central-app policy mismatches: two kind-pack tests still demand
Swift processors that `pluginsOnly` intentionally disables, and recent-URL tests
still expect Swift URL normalization/filtering that the same policy bypasses.
Those policy functions and tests are unchanged by this work.

### Simulator check, October 2026

On iPhone 17 Pro / iOS 26.2, Release, ten measured cold launches per metric
with an empty saves database:

| Metric | Before, mean | After, mean |
| --- | ---: | ---: |
| First frame | 1,059 ms | 980 ms |
| Responsive | 1,117 ms | 1,030 ms |

Relative standard deviations were 2.5% / 1.9% before and 1.6% / 0.8% after.
These measurements cover the catalog, speech and reveal changes; the subsequent
correction to background-launch detection was compile/regression checked. They
are simulator measurements, not an iPhone launch-time guarantee. Sampling also
showed substantial Simulator dynamic-loader time before application code runs.

### Interaction regression checks, 23 October 2026

109 focused simulator tests pass across startup, plugin boot, reader chrome,
progressive rendering/reuse, title glyphs, immersion, onboarding handoff, Settings
hierarchy and reader sharing. A broader selection found four assertion failures
in `PluginsSettingsScreenTests` and `SavesIngestorTranscriptionTests`; the same
four failures were reproduced on untouched `main`. Interactive desktop input
could not be verified with the Mac locked; no physical-phone latency measurement
was taken.

### Launch interaction work, 29 October 2026

A symbolicated Simulator `sample` of a populated launch found send retries on
main after the first frame, reached through the Wi-Fi-available callback.
`retryPendingSends` rebuilt the destination list and reread plugin configuration
for every saved item; a single catalog lookup enumerated all imported plugins.
Lifecycle retries now coalesce on a utility queue, configuration is checked once
per destination per pass, and a catalog point lookup reads only the requested
plugin (preserving imported-over-bundled precedence). Delivery still rechecks
configuration and the current save before sending. A trigger during a running
sweep requests another pass.

Text cards no longer construct unused RSVP and Original readers; the latter's
WebKit view is also lazy. Mode selection retains and reuses the selected reader.
The utility card binds its native paste control when centered, avoiding pasteboard
IPC while opening a neighbouring article. The audio mini-player is built only
when it has playback or a handoff preview to display. Audio-cache cleanup uses
a debounced worker sweep; transcription scratch cleanup and foreground plugin
credential/legacy-send migrations also run on workers. Bluetooth restoration
keeps its required synchronous startup path.

Regression tests cover configuration checks across a 100-save library, worker
execution of lifecycle retries, lazy reader modes and their reuse, and binding
the paste action on card selection. Initial sampling used iPhone 17 Pro / iOS
26.2, Debug. It identifies blocking stacks, not a physical-device latency
promise. Temporary launch timers were removed; no profiling code ships.

Validation: 175 focused simulator tests pass (launch services, send coordinator,
plugin boot/runtime, reader modes, mini-player and utility card). The utility
card's `testAnExpiredEntryIsNoEntry` also fails with the original utility-card
implementation; it was excluded from the final run and left unchanged.
