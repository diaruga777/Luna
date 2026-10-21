# Luna Code

Mac setup, restored connections, account credentials, and adaptive companion UI are
shared across Vault, Music, and Code. See [One Luna Mac connection](mac-connection.md).

Overnight job persistence, retained signed artifacts, attempt diagnostics and
explicit remote **control** addresses are implemented. The full remote-install
scope remains in the [handoff](plans/code-overnight-remote-install.md); see the
[implementation/acceptance report](code-overnight-remote-install-status.md) for
supported behavior and deferred device checks. Physical endpoint enrollment is
wired, including the bounded Apple-service adapter, dedicated reverse streams and
native-to-proxy fallback. Protocol checks include the combined synthetic Apple
fixture through the real private relay and production broker. All physical
acceptance checks remain pending.

Standalone UIKit iPhone/iPad source editor (`com.hsanabria.luna.code`, scheme
`LunaCode`, iOS 26). Most implementation lives in the local `LunaCodeKit` package.
The existing Mac companion is now displayed as **Luna Mac**. Its executable,
bundle identifier, identity directory, peer approval and preferences retain their
Vault identities, so upgrading preserves existing pairing.

## Phone-side refresh and app catalog

The app now has Project, Apps, Refresh and Mac tabs. Apps uses the catalog owned
by Luna Mac, including GitHub import and persistent schedules. The local
`bin/luna-code` CLI and bundled `plugins/luna-code` MCP use that same catalog over
an owner-only Unix socket. Remote catalog RPCs reuse Luna's authenticated Code
channel; no separate Orbit server or identity is required.

See [agent tool setup](code-agent-tools.md) and [Mac-free refresh](code-local-refresh.md) for cached builds, signing on the
phone, LocalDevVPN, Personal Team setup and acceptance limitations. This is
independent of the Mac's overnight build/install path. Run
`python3 scripts/bootstrap_code_refresh.py` before building from a fresh checkout.
Orbit's complete source history is retained in Git tag
`archive/orbit-before-luna-return-20261021`.

## Setup and use

1. Build/run the Mac companion with `script/build_and_run.sh`. It requires Xcode
   command line tools. `--build-only` packages without launching or stopping it.
2. Pair in either Vault or Code. Both iOS apps use the same App Group, TLS identity,
   approved Mac, discovery and connection preferences. Use the existing LAN or
   separately installed Tailscale client. There is no second account or relay.
3. Browse Mac Files; select an `.xcworkspace` (when used by the project) or
   `.xcodeproj` to open its containing source folder immediately. Navigate folders
   and open existing text files. Browser Actions offers Project Files, Browse Mac
   Files, Choose Build Scheme, Project Settings, hidden files, and absolute-path navigation. The gear
   opens Mac Connection. Scheme setup never blocks browsing: choose a scheme in
   Choose Build Scheme, Project Settings (leave Scheme empty), or when first
   starting a build. Loading, empty folders, and failures have explicit states
   with a Retry action for failures.
   The last project automatically reopens on launch, along with its last open
   source file when available. Project/file restoration is isolated by Mac and
   project; old saved selections migrate automatically. Closing the last file
   returns to the project browser and keeps it closed on relaunch. Changing
   projects flushes drafts before replacing the previous project's editor tabs.
4. **Prepare Code Intelligence** builds the selected Debug simulator scheme. This
   creates the SDK, package modules and compiler arguments needed by SourceKit.
   Re-run after changing dependencies/build settings. Build also refreshes artifacts.
5. Edit, then **Save to Mac** (⌘S). Drafts persist on iPhone between sessions and
   are isolated by Mac identity. Saving uses a content version; if the Mac changed,
   choose **Use iPhone Version** or **Use Mac Version**. Clean open files refresh
   from the Mac every four seconds while foregrounded. Dirty files retain drafts.
6. Set the ASC app ID and **internal group ID** in Project Settings. **Build & Deploy
   to TestFlight** saves dirty open files, archives/signs/uploads on Mac, waits for
   processing and assigns the build to that group. Install it using TestFlight.
   TestFlight installation uses Apple’s TestFlight app. The Mac must stay awake/connected;
   the phone may disconnect after the job starts and reopen its persisted job log.

The unsandboxed Mac companion can browse its accessible filesystem. macOS still
controls protected directories; grant Luna Mac access in System Settings when
needed. Before Code file/project operations, the Mac performs a bounded read-only
folder-access probe. A permission prompt that blocks longer than eight seconds
returns an actionable error instead of leaving the iPhone loading. Denials point
to Files and Folders / Full Disk Access. Luna Mac displays the same access issue.
Retry after answering the system prompt; no write runs until the probe succeeds.
Code can modify existing regular source files up to 2 MB, preserving
UTF-8/UTF-16 BOM, line endings and permissions. Open original paths for symlinks.
New files, deletion, rename, Git UI and graphical Xcode project editing are outside v1.

## Project and Builds tabs

**Project** retains the single-project file browser, editor, scheme settings,
code intelligence and TestFlight controls. **Builds** lists the runnable iOS apps
from previously opened projects, with one row per runnable iOS app scheme. Alias
schemes sharing a bundle remain separate and keep independent branch, phone and job settings. The app restores the last selected tab.
Project history, cached app rows, row options and job IDs are isolated by paired
Mac and survive relaunch. Opening another project does not clear the build list.
Rows use a self-sizing layout with the app’s icon and name above build history,
and a separate control row for Overnight, Run and options. Accessibility text sizes
stack the control groups vertically. Icon thumbnails come from the target’s configured
app icon asset set, travel with discovery and remain cached offline. Rows show scheme
when it differs from the app name, last successful compilation time and the short Git commit hash,
plus the current job state. Project, branch and phone details remain in row options.
Compilation history is persisted on both Mac and phone, survives refresh/relaunch,
and remains visible even if subsequent installation fails. Alias schemes retain
independent history. Older jobs without metadata display “Not built yet” until a
new build records its revision.
Rows remain visible offline; pull to refresh discovers new schemes and devices.
Discovery publishes apps progressively and excludes test, extension and Mac targets.
Multi-app collection schemes (such as AllLunaApps), even with a Run target, and
package schemes without a Build action are skipped. Successfully excluded cached
rows disappear as each scheme is checked. An individual scheme failure
keeps its cached row, reports the error and allows discovery of later schemes.
Discovery and job polling update existing rows in place, preserving open build
options menus. Menus read current branch, device and job settings when opened.

Tap a row's play button to build Debug, install and launch on the default phone.
The default is the current phone when its device name uniquely matches, otherwise
the only connected iOS device. If there are multiple choices, select a default
once; iOS does not expose the phone's UDID. A saved but disconnected phone never
silently falls back to a different device. Phones must be connected to the Mac,
trusted, unlocked and set up for development in Xcode. Discovery uses Xcode’s
available physical iOS devices (`xcdevice list`), including USB and Wi-Fi phones
whose CoreDevice development tunnel has not opened yet. Remembered unavailable
phones, simulators and devices with Xcode errors are excluded. Before compiling,
the Mac rechecks availability and the selected scheme’s iOS destinations; an ineligible phone
fails with connection, Developer Mode and Xcode setup guidance.

The row's **•••** menu offers target device, branch, Open in Project,
persisted build log and cancellation. Row settings are independent of the editor.
Each row also has an **Overnight** switch, off by default. Enabled schemes request
one Debug build/install per local calendar day, from 1–6 AM. Charging and public
internet are not global task requirements. A `BGProcessingTask` registers at app
launch and records an invocation before connecting. Expiration immediately
records that invocation's result, closes its control session, and completes the
task once; already accepted Mac builds continue. Manual **Try Now** uses the same
Wi-Fi/provider checks and bypasses only the time window. Turning off a scheme
prevents new submissions; cancelling accepted work is a separate action.

A Code-only connection tries at most two numeric LAN candidates first (IPv4 or
IPv6 on an associated Wi-Fi interface), then explicitly configured remote
addresses in their configured order. **Luna Mac → Overnight Builds** configures a
Tailscale `tcp://` address or a specific Syncthing `relay://` address. There is no
implicit relay pool lookup, public discovery, embedded tsnet, login, or cellular
fallback. Wi-Fi is checked before each RPC/dial, including under a VPN; unsupported
association checks skip the attempt. Local Network consent must be acquired in
foreground. Shared Vault/Music connection policy and synchronized credentials are
unchanged. See the status report for enabling the Mac's relay listener.

The new coordinator negotiates versioned capabilities, reconciles prior jobs and
requests installation of an existing artifact before submitting new compilation.
Daily request IDs include Mac/device/scheme/schedule generation and a calendar
date string, so DST or a time-zone change within that date cannot duplicate an
accepted operation. The Mac durably persists acceptance before replying. A newer
terminal revision cannot be replaced by an older poll. Restart interrupts unfinished
compilation explicitly, restores retained artifacts, and marks interrupted installs
as needing confirmation. One install lock covers both foreground Build & Run and
overnight installs targeting the same phone.

For an enrolled phone, native reachability failure can fall back to dedicated
phone-initiated TLS streams over the selected explicit LAN, Tailscale or Syncthing
address. Apple host pairing keys remain on Mac. The pinned helper verifies Apple's
paired certificate and actual UDID before requesting AFC/Installation Proxy ports,
uploading and reading back the exact revision. A private job-token Unix broker
connects it to bounded LCDF flows; no public host/port proxy is exposed. Readiness
expires using monotonic clocks and ends when iOS runtime/Wi-Fi ends. No scheduled
path launches an app. Updating Luna Code itself is unsupported through its own
forwarder and requires an independent Apple device connection.

Generic iOS Debug builds use detached committed-ref checkouts and ordinary
Xcode development signing. The signed `.app` is copied to `Code/Jobs/Artifacts`
before checkout cleanup, with SHA-256 tree digest, bundle/version/build, source
commit, selected phone and signing metadata. The main app's Info.plist must use
`CURRENT_PROJECT_VERSION`; the overnight build supplies a distinct build number
and rejects a product that ignores it. Signature, profile expiry, main/extension
provisioning eligibility and digest are checked again before installation.
Artifacts have an 8 GiB hard quota; ready/uncertain evidence is protected during
pruning. Native installation uses `devicectl`, never launches, and confirms the
exact installed bundle/version/build. Inconclusive readback is unknown completion,
not a confirmed installation. CoreDevice's automatic route is labelled
`nativeAutomatic`; it is not described as a proven LAN/Tailscale underlay.

**Authorize This Phone** in Overnight Builds binds a device-only installation key
to the chosen physical UDID. The Mac writes a random challenge into the configured
Code app's private container over its Apple connection, then reads back that
phone's signature. The shared Luna account alone cannot assert a physical UDID.
Challenges expire after five minutes; Mac restart drops unfinished enrollment.
Completion persists before replying and can be retried after a lost response.
The same action removes this phone's authorization. Forgetting Luna Mac revokes
all saved bindings. Mac builds derive the allowed Code bundle ID from the namespace
configuration (`LUNA_CODE_BUNDLE_ID` overrides it for a differently named app).
Physical enrollment remains pending. A staged, signed Mac helper enables the
app-hosted installation pipe; the Mac advertises native-only installation if the
helper is missing. Each readiness and fresh stream also proves the phone-only key.

**Overnight Builds** shows the last actual invocation, build and confirmed
installation separately, next requested date, synchronization age and recent
records. It supports refresh, explicit installation retry/cancellation and a
redacted export that includes the available Mac journal or a missing-Mac marker.
After-first-unlock iOS files and owner-only Mac state retain up to 30 days/200
completed summaries plus actionable/uncertain jobs and the most recent successes.
JSONL journals rotate at 1 MB each (two files); bounded native-installer diagnostics
retain at most 18 MB separately. Compiler/build logs retain their existing policy
and are excluded from automatic exports because they can contain source text.

Background keys retain their existing after-first-unlock protection. Apple’s
services may refuse installation while locked or unavailable; the artifact remains
available for retry. iOS chooses whether/when background execution runs. The Mac
must stay awake. Neither daily execution nor locked-device installation is promised.

Direct LAN access is already available with a pairing code containing the Mac’s
LAN address. It cannot reliably cover guest/client-isolated Wi-Fi, VLAN boundaries,
blocked peer traffic or multicast restrictions. No additional general-purpose LAN
feature was added because those network policies cannot be bypassed by an app.

Quick builds default to committed local **main**. The Mac resolves the selected
Git ref into an isolated detached checkout, builds there, then removes it. The
editor's branch, index, unsaved files and iPhone drafts are not changed or saved
by quick builds. Xcode signing must already be configured on the Mac. If the
detached checkout has no development team, Build & Run resolves the original
project's Debug iOS team (including ignored local `.xcconfig` settings) and passes
it to Xcode for the app and embedded extensions. A team committed on the selected
branch takes precedence. Local configuration files and edited source are never
copied into the checkout. A missing team in both projects returns setup guidance
before compilation.
Installation and launch use Apple's `devicectl`; no device UI automation is used.
Build startup holds a finite iOS background lease before device discovery, saves
and the start RPC, and requests an iOS 26 continued-processing task. During this
handoff, the app says to keep Luna Code open until the Mac acknowledges the job.
After acknowledgement, it explicitly says that Luna Code can be backgrounded.
The scene keeps the Mac connection alive during startup and active monitoring;
backgrounding no longer tears down an in-flight start request.

Build rows, the editor and the build summary show a work-based estimated bar,
the current compiler/linker/signing operation and the actual completed task count.
Luna Mac tails `xcodebuild -resultStreamPath` while the command runs, counting
command-invocation start/close events rather than console lines or elapsed seconds.
Fragmented, duplicate, malformed and oversized stream records are handled without
blocking build logs or cancellation. Completed counts and operation names persist
with the job, including the final result.

Xcode's result stream does not provide a reliable total task count. The percentage
uses the last successful workload for that project/scheme/destination, or a bounded
work-count estimate on the first build. Real task completions advance it; time alone
does not. Preparation, checkout, signing checks, installation, launch and cleanup
advance at confirmed milestones. The overall percentage remains labelled estimated,
never moves backward within a job, and reaches 100% only after confirmed job success.
TestFlight captures the archive's real task events, then holds an explicit
archive-complete/export/upload/processing phase until `asc publish` finishes.
Older companions without progress metadata retain the bounded elapsed-time fallback.
Failure, cancellation and a lost Mac connection freeze displayed progress.

The shared, tab-independent monitor polls accepted jobs and drives the app UI and
`BGContinuedProcessingTask.progress` from the same estimate. iOS supplies the
system progress Live Activity; no custom widget or push service is needed.
If iOS declines background runtime, the app says background progress is unavailable;
the Mac still owns accepted work and reopening refreshes status. If the Mac becomes
unreachable, the displayed estimate freezes and the app reports reconnection.
System expiration or dismissal stops monitoring, preserving the Mac's build;
use Cancel Build in Luna Code to cancel the actual job. Active job IDs survive
relaunch, and foregrounding resumes status checks.

When the built app's actual bundle ID matches the monitoring app's bundle ID,
Luna Mac pauses before installation and publishes a tokenized handoff. Luna Code
flushes open drafts and ends its system activity successfully as **Build complete —
updating Luna Code**, then acknowledges the token under a short background lease.
Only that acknowledgement releases installation. The Mac job remains running;
installation/launch can still fail and the replacement app restores the final result.
A persisted handoff marker and the Mac's job metadata suppress a replacement activity
on relaunch. A missing acknowledgement times out after two minutes and fails without
installing; cancellation also prevents installation. The bundle comparison is
conservative when building the same app for another phone: its monitoring activity
also ends at the compilation boundary. This avoids guessing the current phone's UDID.
Update both Luna Code and Luna Mac for this protocol; older clients don't request
the handoff. TestFlight's later user-initiated app update is separate from this direct
Build & Run installation flow.

Console output is opt-in via Show Console or the row’s Build Log menu. The Mac owns
the job independently of the iPhone connection; status and logs persist. Keep the
Mac awake and the target phone reachable for installation and launch.

## Editor

Runestone's native text system and Tree-sitter provide Swift, C-family, JavaScript
and JSON highlighting, line numbers, indentation, bracket pairs, selection and
undo. Other UTF-8/UTF-16 sources open as plain text. Native Find & Replace,
wrapping and adjustable type size are available from the editor menu.

The phone uses full-width editing; the file navigator opens separately. iPad uses
a sidebar. Portrait shows cursor/issue status; short landscape windows collapse
secondary chrome while the keyboard is up. The keyboard layout guide preserves
usable editor space, with a horizontally scrolling coding accessory row. Rotation
preserves text, selection and undo. File tabs preserve each document's undo stack.

Hardware keyboard: ⌘S save, ⌘F find/replace, ⌘⇧O open path, ⌘/ comment,
⌘W close, ⌘B build, ⌘[ / ⌘] outdent/indent, ⌘1 files, Control-Space completion.
Completion supports arrows, Return/Tab and Escape. Native selection, clipboard,
undo and redo remain available. Touch has equivalent editor/accessory actions.

Project Settings uses a grouped form with separate Project and TestFlight sections.
Empty editor and browser states use system unavailable-content views with direct
actions. Build rows show scheme, compilation date, commit hash and job state; the build screen keeps console output optional. Editor tabs
retain their views while typing and truncate long filenames in the middle.

## Compiler investigation and implementation

SwiftParser performs **local syntax checks**, including offline. An ordinary iOS
app has no supported Xcode SDK/compiler service to type-check arbitrary UIKit and
third-party application projects. Shipping Mac build products does not supply an
iOS-hosted Swift toolchain. Swift Playgrounds' Apple-provided compiler integration
is not a public API for embedding in other apps.

Semantic checks and non-LLM completion run through Xcode's **SourceKit-LSP on Mac**.
Unsaved buffers go through LSP; they are never written to disk for analysis. This
supports UIKit and compiled external modules (e.g. GRDB when part of the selected
scheme). A bundled MIT xcode-build-server reads the scheme's build activity log;
Luna writes a managed `buildServer.json` beside the project. Existing unmanaged
configs are preserved. `-resultBundlePath` ensures xcodebuild retains activity logs.
Swift 6.2 caches completion sessions by position even when receiver types change;
the bridge invalidates that session when the surrounding buffer changes.

References: [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp),
[xcode-build-server](https://github.com/SolaWing/xcode-build-server),
[SwiftParser](https://github.com/swiftlang/swift-syntax),
[Runestone](https://github.com/simonbs/Runestone),
[Swift Playgrounds](https://developer.apple.com/swift-playgrounds/).

## Transport, saves and jobs

Code uses the existing authenticated BEP connection (`luna-code-v1` request
namespace), behind the same approved-peer gate as Vault. Payloads are bounded.
The companion accepts concurrent Vault/Code sessions from the paired identity.
The optional explicit relay listener shares the Mac account authorization.
Device-flow keys and leases are separate reusable primitives; they are not yet
used to authorize production Apple-service forwarding.

Saves coordinate with macOS, compare SHA-256 versions, write/fsync a temporary
sibling and atomically replace the file. Modified iPhone text survives conflicts,
network failures and restarts (draft debounce 250 ms, immediate flush on background,
file switch and explicit Save). Local Mac applications that bypass file coordination
can still race the final replacement; v1 does not offer collaborative editing.

Build jobs have IDs, disk logs and persisted status under the companion's Code/Jobs
state. Only one build/deployment executes at a time; accepted overnight jobs queue behind it; restarting the companion marks
interrupted compilation jobs failed. The separate overnight store retains ready
artifacts and uncertain installation evidence. Commands use argument arrays, never shell interpolation.
`asc publish testflight` handles build-number allocation, archive, export, upload,
processing and internal distribution. Credentials remain on Mac using existing
`asc` configuration (`~/.blitz/bin/asc`, Homebrew, or `LUNA_ASC_PATH`). Xcode signing
must already work for the selected project. No private API key is sent to iPhone.

## Verification

- `swift test --package-path LunaCodeKit`: revision-ordered journals, lost acceptance replies, artifact reuse, restart/uncertain-install recovery, exact readback, signature/digest identity, restricted stream bounds/revocation/half-close, redacted exports, daily overnight windows/DST, default-off switches, complete batch submission without polling, Mac queue draining, companion capability checks, persistent idempotency and compilation history, build-cache/option persistence, phone selection,
  live-device filtering, Xcode destination eligibility, app Run-target selection, multi-app collection exclusion, configured icon thumbnails, same-bundle scheme isolation, permission preflight, detached main checkout isolation/cleanup, local signing-team fallback and committed-team precedence, command-log retention,
  structured build-event parsing, fragmented/duplicate/oversized records, event-driven progress,
  acknowledged self-install gates, timeouts/cancellation, bundle matching,
  terminal progress, backward-compatible job payloads, interrupted-job recovery,
  file versions/conflicts, encoding,
  permissions, binary/oversize rejection, symlinks, draft isolation and RPC retries.
- `scripts/test_code_intelligence.sh`: disposable real UIKit app plus external
  Swift package; verifies completion changes with receiver type, unsaved semantic
  diagnostics and unchanged on-disk source. Also exercises scheme listing and a
  real build through CodeService, with persisted job recovery. Requires Xcode and
  the repo Ruby gem.
- `xcodebuild test -scheme LunaCode -destination 'platform=iOS Simulator,id=…'`:
  isolated simulator preview, portrait/landscape typing, explicit Save,
  draft recovery, project/workspace selection and restoration, project switching,
  scheme selection, cached app rows/icons, nonoverlapping build controls at default
  and accessibility text sizes, one-tap main build requests, hidden console,
  background/foreground job status, immediate backgrounding during delayed startup,
  progress accessibility, completed task/current operation display,
  self-update handoff and final-result restoration after process replacement, last-tab restoration,
  browser failure/recovery, and explicit save-conflict resolution;
  iPadOS hardware Save shortcut. Preview mode is unavailable in Release and on physical devices.
- `LunaVaultConnectionTests`: approved-peer gate for Code alongside existing pairing,
  browser, index and transport tests. Never use WebDriverAgent on a physical iPhone.

A live production TestFlight upload is not part of automated tests. Physical
Bluetooth keyboard behavior should also be checked on device before release.
