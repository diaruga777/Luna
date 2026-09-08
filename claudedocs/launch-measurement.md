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
