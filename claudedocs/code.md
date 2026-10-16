# Luna Code

Mac setup, restored connections, account credentials, and adaptive companion UI are
shared across Vault, Music, and Code. See [One Luna Mac connection](mac-connection.md).

Standalone UIKit iPhone/iPad source editor (`com.hsanabria.luna.code`, scheme
`LunaCode`, iOS 26). Most implementation lives in the local `LunaCodeKit` package.
The existing Mac companion is now displayed as **Luna Mac**. Its executable,
bundle identifier, identity directory, peer approval and preferences retain their
Vault identities, so upgrading preserves existing pairing.

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
   iOS cannot silently install or replace itself. The Mac must stay awake/connected;
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
Rows remain visible offline; pull to refresh discovers new schemes and devices.
Discovery publishes apps progressively and excludes test, extension and Mac targets.
Package schemes without a Build action are skipped. An individual scheme failure
keeps its cached row, reports the error and allows discovery of later schemes.
Discovery and job polling update existing rows in place, preserving open build
options menus. Menus read current branch, device and job settings when opened.

Tap a row's play button to build Debug, install and launch on the default phone.
The default is the current phone when its device name uniquely matches, otherwise
the only connected iOS device. If there are multiple choices, select a default
once; iOS does not expose the phone's UDID. A saved but disconnected phone never
silently falls back to a different device. Phones must be connected to the Mac,
trusted, unlocked and set up for development in Xcode. Remembered disconnected
phones are excluded. Before compiling, the Mac rechecks the live connection and
Xcode’s available iOS destinations for the selected scheme; an ineligible phone
fails with connection, Developer Mode and Xcode setup guidance.

The row's **•••** menu offers target device, branch, Open in Project,
persisted build log and cancellation. Row settings are independent of the editor.
Quick builds default to committed local **main**. The Mac resolves the selected
Git ref into an isolated detached checkout, builds there, then removes it. The
editor's branch, index, unsaved files and iPhone drafts are not changed or saved
by quick builds. Xcode signing must already be configured on the Mac.
Installation and launch use Apple's `devicectl`; no device UI automation is used.
Accepted jobs show a spinner and a message confirming that Luna Code can be
backgrounded. Console output is opt-in via Show Console or the row’s Build Log
menu. The Mac owns the job independently of the iPhone connection; status and
logs persist, and the foregrounded app polls for completion. Keep the Mac awake
and the target phone reachable for installation and launch.
Update both Luna Code and Luna Mac for these new protocol operations.

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
actions. Build rows show project, branch, phone and job state without permanent
instructional footers; the build screen keeps console output optional. Editor tabs
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
There is no additional listener, pairing database, key or credential exchange.

Saves coordinate with macOS, compare SHA-256 versions, write/fsync a temporary
sibling and atomically replace the file. Modified iPhone text survives conflicts,
network failures and restarts (draft debounce 250 ms, immediate flush on background,
file switch and explicit Save). Local Mac applications that bypass file coordination
can still race the final replacement; v1 does not offer collaborative editing.

Build jobs have IDs, disk logs and persisted status under the companion's Code/Jobs
state. Only one build/deployment runs at a time; restarting the companion marks
interrupted jobs failed. Commands use argument arrays, never shell interpolation.
`asc publish testflight` handles build-number allocation, archive, export, upload,
processing and internal distribution. Credentials remain on Mac using existing
`asc` configuration (`~/.blitz/bin/asc`, Homebrew, or `LUNA_ASC_PATH`). Xcode signing
must already work for the selected project. No private API key is sent to iPhone.

## Verification

- `swift test --package-path LunaCodeKit`: build-cache/option persistence, phone selection,
  live-device filtering, Xcode destination eligibility, app Run-target selection, same-bundle scheme isolation, permission preflight, detached main checkout isolation/cleanup, command-log retention,
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
  scheme selection, cached app rows, one-tap main build requests, hidden console,
  background/foreground job status, last-tab restoration,
  browser failure/recovery, and explicit save-conflict resolution;
  iPadOS hardware Save shortcut. Preview mode is unavailable in Release and on physical devices.
- `LunaVaultConnectionTests`: approved-peer gate for Code alongside existing pairing,
  browser, index and transport tests. Never use WebDriverAgent on a physical iPhone.

A live production TestFlight upload is not part of automated tests. Physical
Bluetooth keyboard behavior should also be checked on device before release.
