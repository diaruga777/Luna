# Staged mode — every screen, in every state, one launch away

```sh
xcrun simctl launch <sim> com.hsanabria.luna.reader -LunaStage reader.rsvp
```

A **stage** is a named screen in a named state, reachable by launch argument
with stubbed data and nothing to set up: no onboarding to answer, no account to
connect, no permission sheet, no network. Seventy-odd of them span all four
apps.

It exists for two reasons.

**One launch per screen, instead of a navigation script per screen.** An agent
driving the simulator to review a layout used to have to reach the screen —
save something, wait for it to ingest, open settings, scroll, tap. Every step is
a coordinate that moves with the layout and a wait that is either flaky or slow.
`-LunaStage settings.email.error` is none of that.

**States a real run only passes through.** A download is through
resolving/downloading/failed inside a few seconds. A sign-in spinner lasts as
long as the network does. A rescue resolves. None of them can be photographed
from the outside. A stage *describes* the state instead of producing it, and
staged mode suppresses everything that would move it on.

DEBUG-only. See "Why `#if DEBUG`" below.

## Using it

```sh
# What can this app show me?
xcrun simctl launch --console-pty <sim> com.hsanabria.luna -LunaStageList

# Show me one of them.
xcrun simctl terminate <sim> com.hsanabria.luna
xcrun simctl launch <sim> com.hsanabria.luna -LunaStage deck.product.alerting
xcrun simctl io <sim> screenshot shot.png
```

`terminate` first: `simctl launch` on a running app just foregrounds it and your
new argument is ignored.

The stage is live UI, not a picture — tap it, scroll it, drive it. What it will
not do is fetch anything, so a tap that needs the network dead-ends.

Two arguments, both inert when absent:

| Argument | Effect |
|---|---|
| `-LunaStage <id>` | Boot into that stage. An unknown id is a hard failure listing the known ones — a capture of the wrong screen is worse than no capture. |
| `-LunaStageList` | Print the manifest as JSON on stdout and exit. |

The committed manifest, `Luna/Stage/StageManifest.json`, is the same JSON for
the central app (which links every kind, so its catalog is the complete set).
Read it instead of booting a simulator; `StageRegistryTests` fails if the two
drift.

### Stage ids

`<area>.<screen>.<variant>`, lowercase, hyphenated — typed verbatim into a
shell, so no spaces and no capitals.

| Id | What it shows |
|---|---|
| `deck.first-run` | The card deck with nothing saved and onboarding unanswered |
| `deck.article.locked` | The deck centred on a hard-paywalled save |
| `deck.product.alerting` | A price drop past its threshold, unacknowledged |
| `reader.rsvp` | The RSVP speed reader over the fixture article |
| `card.media.downloading` | A media card frozen mid-transfer at 45% |
| `settings.email.error` | Email settings after the provider rejected the account |

An id is not a user-visible string, so it does not go through `L10n`. Staged
mode adds no chrome of its own and therefore no copy.

## Screenshot guide

`scripts/stage_screenshots.py` builds all four apps, boots a simulator,
installs, asks each app for its own manifest, launches every stage in turn,
screenshots it, and writes a Markdown guide grouping the lot by app → screen →
state.

```sh
scripts/stage_screenshots.py                    # everything (~10 min)
scripts/stage_screenshots.py --apps reader      # one app
scripts/stage_screenshots.py --only 'deck\.'    # one family
scripts/stage_screenshots.py --no-build         # reuse built products
```

Output lands in `build/stage-screenshots/` — **gitignored**, deliberately. The
guide is only meaningful with its couple of hundred megabytes of PNGs beside
it, and a screenshot set in the repository is stale the day after it is
committed. Regenerate it when you want to look.

It waits for the screen to STOP CHANGING rather than sleeping a fixed amount.
That is not politeness: a settings list draws in under a second, and a deck
stage whose centred card is a live WebKit reader takes the better part of ten on
a cold simulator. A fixed wait either captures black or triples the run.

## How it works

Four steps, in this order, and the order is the whole design.

**1. `LunaStage.prepareIfNeeded()`, first line of `didFinishLaunching`.**
Before anything can resolve a store, `StageContainer.activate` points the
shared container at a throwaway directory and a scratch defaults suite.
Everything after it — including the app's own launch bookkeeping — writes to
scratch.

**2. `KindWiring.install()` installs the catalogs.** Each app installs the
catalogs for the kinds it links, and only those.

**3. `LunaStage.finishLaunchIfNeeded()`, last line of `didFinishLaunching`.**
Answers `-LunaStageList` — by which point every catalog is registered — and
exits.

**4. `SceneDelegate` asks for a root.** The stage's `seed` runs, then its
`make` builds the screen. A stage with no `make` falls through to the app's own
root with the store already seeded.

### Statelessness

Two redirects, both in `LunaAppConfig` at the bottom of the stack, because that
is where every shared store already resolves from:

- `AppConfig.sharedContainerURL()` — the App Group DIRECTORY (`saves.sqlite` and
  its `-wal`/`-shm` siblings, `Articles/`, saved media, the weekly mirror). Eight files used to call
  `containerURL(forSecurityApplicationGroupIdentifier:)` themselves; they all go
  through this now.
- `AppConfig.appGroupID` — the defaults SUITE NAME. Two dozen stores build a
  `UserDefaults(suiteName: AppConfig.appGroupID)`, so swapping the id redirects
  every one of them with no per-store plumbing.

Plus one exception: `AppOnboardingStore` deliberately uses **standard** defaults
(each host owns its own onboarding), so `StageContainer.standardDefaults()`
redirects that too. It is the one call site; anything else reading standard
defaults is per-device configuration a stage has no business rewriting.

> **A store that resolves the container ITSELF is invisible until a stage
> exercises it.** The appender every share/action surface used to append
> through — since folded into `SavesStore`'s own insert path — was asking the file
> manager directly, so a staged save
> landed in the REAL App Group while the store read the scratch one. The
> row appeared to vanish between the append and the lookup one line later: the
> onboarding lesson's product rehearsal fell back to a bare "Saved" confirmation
> instead of opening the price editor, with nothing in the log to say why. If a
> staged save ever goes missing again, this is the shape of it. (`ProductSnapshotStore`
> now resolves the same `saves.sqlite` path; a stage that needs snapshots isolated
> must construct it with the staged directory.)

> **The scratch suite must not be named `group.…`.** cfprefsd resolves a suite
> with that prefix as an app-group container, the process is not entitled to a
> group it invented, and the suite comes back unusable — silently sending every
> defaults-backed store back to the REAL one. This cost an afternoon; the suite
> is `LunaStage.<run>` for that reason alone.

Not covered: the **Keychain**. `EmailAccountStore.shared` writes credentials to
the shared access group, so an email stage builds its own store on
`InMemoryCredentialStorage` rather than touching `.shared`.

### Freezing

`LunaStage.isActive` gates the launch-time work that would move a staged screen
out from under itself, all in `AppDelegate`/`SceneDelegate`:

| Skipped | Why |
|---|---|
| `SavesIngestor.ingestAllPending()` | Would resolve the save a stage froze mid-fetch |
| `KindWiring.appDidLaunch()` | Its media purge deletes the media a stage just seeded |
| The weekly pull, mail import, price refresh, proposal check | Network; each would overwrite seeded state |
| Spotlight indexing, image-reference backfill | Write to state a stage owns |
| `applicationDidEnterBackground`, `sceneWillEnterForeground` | A capture pass backgrounds and returns; neither should reflow the screen |

The BGTask **registrations** are deliberately NOT skipped — an identifier has to
be claimed before launch returns, and a registration alone runs nothing.

**Animations stay ON.** Turning them off globally is the obvious way to make a
capture deterministic and it is wrong here: the card carousel mounts its cards
through an animated path, so `UIView.setAnimationsEnabled(false)` rendered every
deck stage as a black screen. Determinism lives in the harness instead, which
waits for two identical frames.

Staged runs do count as a capture for `CaptureLaunch.isActive`, so the
simulator-only debug tap targets ("Sim Dive", the save row ellipsis) do
not overlay the content. That list of launch arguments lives in exactly one
place (`LunaAppConfig.CaptureLaunch`) — it used to be hand-copied into the app
shell and both reader view controllers, and adding `-LunaStage` to the app's
copy alone left the readers still drawing their pills over every capture.

### Catalogs, and the per-app split

Stages follow the kind-pack rule (`claudedocs/surface-support.md`): a kind's
stages live in that kind's own file, and only the targets that link the kind
compile it.

| File | Compiled into | Registered by |
|---|---|---|
| `Stage/StageCatalog+Shared.swift` | all four | every `KindWiring` |
| `Stage/StageCatalog+Article.swift` | Luna, Reader | `KindWiring+Luna`, `+Reader` |
| `Stage/StageCatalog+Email.swift` | Luna, Reader | `KindWiring+Luna`, `+Reader` |
| `Stage/StageCatalog+Media.swift` | Luna, Downloader | `KindWiring+Luna`, `+Downloader` |
| `Stage/StageCatalog+Product.swift` | Luna, PriceTracker | `KindWiring+Luna`, `+PriceTracker` |

The per-kind files carry **membership exceptions** in `project.pbxproj` (they
build app-shell card types, which are themselves per-target), so a single-kind
app cannot even name another kind's screens.

Email is its own catalog rather than part of the article one. The app sets are
identical today — `sharesByEmail` and `handlesArticles` are both
`{Luna, Reader}` — but the reasons are unrelated, and an app could gain articles
without gaining a mailbox.

### The two shapes of a stage

A stage either builds a screen or it does not.

**`make == nil` — a deck stage.** It seeds and lets the app construct its own
root. Faking the deck would have been easy and would have drifted from the thing
it was standing in for; the deck is the screen most worth reviewing.

**`make != nil` — everything else.** The stage builds the screen at the same
construction seam the unit tests use, so a staged screen and its snapshot test
are looking at the same object. `StageCardHostViewController` puts a card in the
deck's exact frame (`CardDeckGeometry.cardFrame` is pure arithmetic over the
screen — `claudedocs/card-carousel.md`); `PresentingHostViewController` handles
the ones that only exist as a modal.

## Adding a stage

1. Pick the catalog for its kind (`Stage/StageCatalog+<Kind>.swift`).
2. Add a `StageDescriptor`: `id`, `screen`, `variant`, a one-line `summary` a
   reviewer will read in the guide, the `kind`, and a `seed` and/or `make`.
   Fixtures go in `StageFixtures` — reuse `UITestFixtures`' dates and seeded ids
   so a stage and its snapshot test agree.
3. Regenerate the manifest:
   ```sh
   xcrun simctl launch --console-pty <sim> com.hsanabria.luna -LunaStageList \
     | sed -n '/^{/,/^}/p' | grep -v '^[[:space:]]*$' \
     > Luna/Stage/StageManifest.json
   ```
4. Run `StageRegistryTests`.

Adding a whole new kind catalog also means a `<Kind>StageCatalog.install()` call
in each `KindWiring` that links it, membership exceptions for the targets that
do not, and a row in `StageRegistryTests.expectedCatalogs`.

## Coverage, and what is out of scope

Covered, across all four apps: the card deck (first run, empty, populated,
failed save, weekly pick, and each kind's card states — locked, fetching,
part-read, from a contact, queued/resolving/downloading/waiting/failed/no-media,
steady/alerting/never-refreshed); the util card (first run, completed with
Safari history, email nudge earned, week- and month-tier weekly picks); the
readers (scroll, highlight, RSVP, inline header, nested split-web); the audio
mini-player (playing, paused, up-next, slim); the failed-save card (error,
rescuing, no-rescue, terminal); email settings (signed out, connecting,
connected, rejected, expired) and the contact screens; the price editor
(alerting, no threshold, creation, merge) and the graph and threshold slider on
their own; and the settings tree.

**Out of scope, and why:**

- **Share, action and Safari extensions in their real host.** An extension is a
  different process launched by the system share sheet, which a simulator cannot
  drive, and `simctl launch` cannot reach an `.appex` at all. The screens
  themselves are staged IN-APP instead (`share.reader-article`,
  `share.media-saved`, `card.rescue-failure`, `card.unsupported-save`) — the
  same view controllers the extension presents, minus its host chrome.
- **App Clips and the Live Activity widget.** Same reason: neither is launchable
  by argument, and the Live Activity needs a real `Activity.request` from the
  process that owns it.
- **Anything whose subject is a network round trip** — a live archive render, a
  real paywall unlock, a WKWebView showing a fetched page. Staged mode suppresses
  the network on purpose; a stage of a screen mid-fetch shows the loading state,
  which is usually the point.
- **The App Store / device-only surfaces**: Photos permission flows, ARKit eye
  tracking, the Action Button (no simulator has one — `-forceActionButtonSetup`
  covers the settings layout, not the button).

## Why `#if DEBUG`

The catalogs call `SavesStore.seedForTesting`, `SavedItem(seed:)`,
`SavedMediaStore.seedForTesting` and the other DEBUG-only fixture seams. A
release build cannot compile them, so there is nothing to disable and no flag to
get wrong: in a shipped binary `LunaStage.isActive` is a constant `false` and
`StageContainer` has no way to redirect anything. A build setting would have
been weaker — it can be flipped — and would have needed the fixture seams
promoted out of DEBUG to compile at all, which is the opposite of what we want.
