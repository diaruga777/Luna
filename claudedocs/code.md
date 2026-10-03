# Luna Code

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
   `.xcodeproj`, then a scheme. Open existing text files from its source folders.
   Hidden files and absolute-path navigation are available in the browser menu.
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
needed. Code can modify existing regular source files up to 2 MB, preserving
UTF-8/UTF-16 BOM, line endings and permissions. Open original paths for symlinks.
New files, deletion, rename, Git UI and graphical Xcode project editing are outside v1.

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

- `swift test --package-path LunaCodeKit`: file versions/conflicts, encoding,
  permissions, binary/oversize rejection, symlinks, draft isolation and RPC retries.
- `scripts/test_code_intelligence.sh`: disposable real UIKit app plus external
  Swift package; verifies completion changes with receiver type, unsaved semantic
  diagnostics and unchanged on-disk source. Requires Xcode and the repo Ruby gem.
- `xcodebuild test -scheme LunaCode -destination 'platform=iOS Simulator,id=…'`:
  isolated simulator preview, portrait/landscape typing, explicit Save,
  draft recovery; iPadOS hardware Save shortcut. Preview mode is unavailable in Release and on physical devices.
- `LunaVaultConnectionTests`: approved-peer gate for Code alongside existing pairing,
  browser, index and transport tests. Never use WebDriverAgent on a physical iPhone.

A live production TestFlight upload is not part of automated tests. Physical
Bluetooth keyboard behavior should also be checked on device before release.
