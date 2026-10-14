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
app dies at launch on its first container access. Automatic signing with team
`MM5QBNLXR6` is already set up; the phone must be unlocked and trusted.

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

`AppLaunchServices` defers plugin runtime creation/evaluation, ingest handlers,
rescue setup, script-cache maintenance, mini-player construction, recent-URL
refresh and share-notification cleanup until the root has had a displayed frame.
`AppFirstFrame` waits for two display-link callbacks; dispatching to the main queue
alone is insufficient because it can run before Core Animation commits the window.
Early touches/keyboard presses, App Intents, and background URLSession/mail/price
callbacks demand installation before using services. Cold deep links queue until
installation completes, including Safari hand-offs. Installation happens once,
even if these entry points race the first-frame callback.

Save retries, mail import, indexing, retention sweeps, weekly refresh and price
refresh start once after `AppLaunchTransition.didFinish`. Background-only wakes
retain the one-second scene-connection fallback; lifecycle callbacks and intents
can demand service readiness immediately. The first scene foreground callback
does not duplicate launch refresh. Staged launches install services eagerly and
continue to suppress maintenance.

Normal launches draw the root directly, with no app-owned splash overlay, hold,
or crossfade. The empty util card shows its headline and controls immediately;
the animated intro remains available to explicit visual stages. Safari hand-offs
retain their bounded splash hold. The carousel creates its playback-speed pill
only when a playable card needs it.

Bundled plugin manifests remain cached per catalog, and speech synthesis still
starts only when audio is requested. Audio observers remain installed before
reader construction so populated decks retain their read-aloud behavior.

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
