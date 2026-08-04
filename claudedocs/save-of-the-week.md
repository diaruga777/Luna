# Save of the Week

One curated pick per save type, published to every Luna install through a
public CloudKit database, signed so that only the curator can set it, and
proposable by anyone. It replaces the util card's former hardcoded weekly link.

Module: `LunaLibraries/Sources/LunaWeekly` (linked by the four APPS only — no
extension reads or writes it). UI: `Luna/UtilCard/WeeklySaveRowHost.swift`,
`WeeklyRibbonView.swift`, `WeeklyRowEclipseTransition.swift`, `WeeklyCyclePacer.swift`,
`WeeklyPromotionMenu.swift`, `Luna/Settings/WeeklyProposalsScreen.swift`.

## The value

`WeeklySave` is `(kind, urlString, date, signature)`. The kinds are `article`,
`media`, `product` — one live entry per kind at any time. `date` is when the
entry became "of the week", and it drives both age rules:

| age | meaning |
| --- | --- |
| < 9 days | "… of the week" |
| ≥ 9 days | "… of the month" |
| > 30 days | the entry does not exist |

Both thresholds live on `WeeklySave` with an injected clock, and expiry is
evaluated on READ (`WeeklySaveStore.display(for:)`) — no sweep, no timer, no
migration.

Which kinds an app fetches and shows is `WeeklySaveKind.kinds(for:)`: the
central Luna app takes all three, each faceted app takes its own. The shared
store may hold a kind an app never renders; it simply doesn't ask for it.

## Signing

Ed25519 (`CryptoKit.Curve25519.Signing`) over the canonical message

```
<kind>\n<url>\n<ISO8601 date, seconds precision, UTC>
```

One formatter for both directions (`WeeklySave.canonicalDateFormatter`, no
fractional seconds) so a date that round-trips through CloudKit still verifies.
`WeeklySigning.sign` rounds the date to that precision before signing, which is
why a signed value survives JSON and CloudKit unchanged.

The PUBLIC key is compiled into `WeeklySigning.publicKeyBase64`. **The private
key is not in this repository and must never be committed.** A record whose
signature doesn't verify is treated exactly as though the record did not exist:
the public database is world-writable in principle, and this is what makes that
harmless.

`WeeklyPromotionKeyStore` keeps the private key in the shared App-Group Keychain
(`CredentialKeychain`, service `weeklyPromotionKey`), so ONE paste per device
makes all four Luna apps key-holders. A stored key that no longer derives the
bundled public key reads as absent.

## Storage

`WeeklySaveStore` writes `weeklySaves.json` into the App Group beside the
reading list — the same sidecar pattern as `SaveFailureStore` (NSLock, atomic
write, injectable `containerURL` and clock). It holds a `WeeklySaveDisplay` per
kind (the signed save plus the title, host and thumbnail resolved when the entry
arrived) and the set of proposal record names already announced.

Metadata resolution is NOT in the module: `WeeklySaveRefresher.metadataFetcher`
is a closure the app shell installs at launch, wrapping
`RecentURLMatcher.evaluate(urlString:surface: .luna)`. `.luna` deliberately — a
faceted app must be able to render whichever kind it fetched.

## CloudKit

Everything CloudKit-facing hides behind `WeeklyCloudDatabase`, so unit tests
always inject a fake and never build a container. `CKWeeklyCloudDatabase` builds
its `CKContainer` lazily, on first use.

| record type | record name | fields |
| --- | --- | --- |
| `WeeklySave` | `weekly-article` / `weekly-media` / `weekly-product` (fixed) | `kind` String, `url` String, `date` Date, `signature` Bytes |
| `WeeklySaveProposal` | `proposal-<first 32 hex of SHA-256(trimmed url)>` | `kind` String, `url` String, `date` Date |

Fixed record names are why reads are by record ID — no queryable index needed
for the weekly picks. All of an app's kinds travel in ONE
`CKFetchRecordsOperation` at `.userInitiated` QoS: the launch card is waiting
on this fetch, and the convenience API's default configuration is
discretionary-eligible, which is what used to cost the row a couple of seconds
even on good networks. The proposal record NAME is the per-URL
dedup: proposing the same link twice lands on the same record, and
`serverRecordChanged` is treated as success.

**Every CK error is a soft no-op plus a `DiagnosticLog` line under category
`weekly`.** No container, no network, no iCloud account: the row keeps whatever
it last knew and nothing else regresses. This is load-bearing today — the
container in §Deployment does not exist yet.

`WeeklySaveRefresher` runs at launch and on foreground (debounced to one pull a
minute, one in flight). The launch pull starts EARLY in `didFinishLaunching` —
a `.userInitiated` task kicked off right after the metadata closure is
installed, not the end-of-launch utility housekeeping block — because the util
card wants the row the moment the deck appears. It fetches this app's kinds
(one batched operation, see above), drops anything unverified or expired,
resolves metadata BEFORE writing so the row animates in fully formed — each
kind's metadata concurrently, writing per kind as it lands, so one slow page
doesn't hold the other rows back — and clears a kind the cloud no longer has.

## The util card row

The row is CONDITIONAL. With no live entry for any of this app's kinds the slot
collapses and both layout branches reclaim it (the setup buttons move up in the
first-run state; in the completed state the recent rows take the card's top,
which is a seat the weekly row otherwise does not occupy — see
`claudedocs/util-card.md`).

It is also the one util row that is NOT dressed like Safari history: Luna's own
pick carries the app's colour — a palette wash over the shared black, a
palette-tinted rim instead of the neutral glass one, and the corner flag below —
so it never reads as the first entry of the recents list.

**The weekly noun is a corner flag, not a phrase in the subtitle.**
`WeeklyRibbonView` is a small tinted tab pinned flush to the row's TOP-LEFT
corner, carrying the app's own noun from `WeeklySaveLabels.subtitle` ("Read of
the week", "Deal of the month", …). Three shape decisions, all of them
corrections of a first pass that was a bright pennant across the artwork:

- **it CLEARS the thumbnail** rather than overhanging it. 20pt tall against the
  centred 52pt thumbnail's 22pt top, and the row's layout guarantees the gap
  rather than inheriting it: the artwork is centred as ever *unless* centring
  would put it under the flag, in which case it sits just below. At the weekly
  row's own 96pt the two agree to the point, so nothing moved when the guard
  went in.
- **its trailing edge is ONE arc**, not a swallowtail's two cuts: a single cubic
  that leaves the bottom edge horizontally and turns up to meet the top edge
  vertically, so there is no corner anywhere along the sweep (both tangents are
  load-bearing — drop either and the join reads as a bend). The flag draws only
  that edge; the row's own `clipsToBounds` plus its 16pt continuous corner round
  the flag's outer corner for it.
- **the fill is the palette DIMMED into the row's black**
  (`WeeklyRibbonView.fillColor`, 45% of `LunaSurfacePalette.baseColor` over
  `UtilURLRow.rowBackground`). At full strength the four colours were a patch
  brighter than the pick they label, and two of them — the Reader's periwinkle
  and the Price Tracker's green — had to letter in near-black to stay legible.
  Dimmed, all four clear 4.5:1 against white, so the lettering is simply white
  and the per-app luminance branch is gone.

Two things that did not change: the shape layer holds a RESOLVED `CGColor`, so it
re-applies on `LunaSkyTrait` changes (a style change never arrives under the
pinned-dark trait — see CLAUDE.md); and the flag travels with
`setContentParallax` during a cycle slide, because it names the PICK, not the
slot.

The subtitle is therefore the URL host ALONE — the noun used to sit beside it
behind a bullet and truncate it. The row is `UtilCardLayout.weeklyRowHeight`
(96pt, against a history row's 74) to seat the flag above the pick's own two
lines, and the title starts below the flag (`WeeklyRibbonView.height + 6`) rather
than at a history row's 13pt. VoiceOver reads flag, title, host.

- **Appearing / disappearing**: a 0.24s fade plus a reflow. An appearing row
  fades in IN PLACE — the host is laid out before the animation, so the row
  never grows into its slot from zero. On the launch that animates the intro
  headline the row instead waits, invisible, for the headline's group reveal
  (`claudedocs/util-card.md`).
- **Replaced in place**: `WeeklyRowEclipseTransition` — the card carousel's
  choreography at row scale. The incoming row crosses from 30% out and goes
  solid in the first quarter; the outgoing one flares white at the 80% break;
  the corona blooms at totality and fades on the egress. No dimmer, no peek
  veils, no diamond-ring flare: at row scale the corona IS the effect. The corona's
  `reach` is overridden to 30 because `EclipseCorona`'s own default has a 56pt
  floor sized for a CARD. Consequently the slot's clipping lives in a child
  view and `WeeklySaveRowHost` itself does not clip — the overhang is the
  drawing.
- **Reduce Motion**: a plain crossfade everywhere, and no auto-cycling.

### Cycling (central app only)

Only Luna ever has more than one live kind. `WeeklyCyclePacer` holds the whole
policy with no views in it — the timer exists only while ALL of: ≥ 2 live kinds,
the card centred, the host in a window, the app active, no replacement in
flight, no finger down, Reduce Motion off, and no manual override.

The first swipe latches auto-advance OFF. The latch clears when the card leaves
centre or when the app returns from the background.

Auto-advance and a committed swipe share one settle: a horizontal spring slide
(0.55s, damping 0.86, initial velocity from the gesture), the outgoing row
dipping to 0.85 alpha and the incoming row's content lagging its shell by 14pt.
The pan begins only on horizontal intent (`|vx| > |vy| * 1.5`, the deck's own
page-pan test), so the two gestures never fight.

## Promotion and proposals

`WeeklyPromotionMenu` adds one action to all three decks' long-press menus,
above Archive/Delete. Failed saves get neither verb.

- **Key-holder**: "Promote to {Save|Read|Download|Deal} of the Week" — confirm,
  sign, write the record, and mirror the pick into the local store so it shows
  immediately instead of waiting for the next fetch.
- **Everyone else**: "Propose Save of the Week" — writes a proposal record. A
  signed-out iCloud account is reported rather than failing silently.

The curator's inbox is `Settings → Save of the Week`, a category
`SettingsViewController` appends only when `WeeklyPromotionKeyStore.isKeyHolder`
(Settings is rebuilt on every visit, so pasting the key and coming back is
enough). Promote and Delete both retire the proposal record.

New proposals are found opportunistically at launch/foreground and by the
`com.hsanabria.luna.weeklyProposalCheck` background refresh (4h,
`WeeklyProposalBackgroundCheck`). The identifier is claimed by every app at
launch — it has to be, before `didFinishLaunching` returns — but both the
scheduler and the handler no-op without a key. New record names produce ONE
local notification per batch.

## Entering the key

Settings → five taps on blank space → Diagnostics → **Enter Weekly Key**. The
pasted base64 is validated against the bundled public key; a wrong key is never
stored. A right one also requests notification authorization — this device now
receives proposals, and this is one of only three moments Luna asks (launch does
not; the others are connecting a sending account and committing a price alert
threshold) — and schedules the background check. With a key stored the
button reads "Weekly Key ✓" and offers Replace / Remove.

## Deployment (manual — not automatable)

1. **Developer portal**: create the iCloud container `iCloud.com.hsanabria.luna`;
   enable the iCloud/CloudKit capability on all four app IDs and assign the
   container to each. (Same class of step as the App Group — the App Store
   Connect API can't do it.)
2. **CloudKit Dashboard** (development schema, then deploy to production):
   - `WeeklySave`: `kind` (String), `url` (String), `date` (Date/Time),
     `signature` (Bytes). World read; creator-only write is fine, since only the
     curator's own account ever writes one.
   - `WeeklySaveProposal`: `kind` (String), `url` (String), `date` (Date/Time).
     **Security role change REQUIRED**: Authenticated → Create AND Write, because
     the curator must be able to delete OTHER users' proposal records and
     CloudKit's default is creator-only write. Add a queryable index on
     `recordName` and a sortable index on `date` — the proposals query needs both.
   - Alternative for the schema itself: a device build signed with the real team
     auto-creates it in the development environment on first write. The security
     role and the indexes are still manual.
3. **Copy the private key** into your own installs through the diagnostics
   screen — once per device; the Keychain entry is shared across the four apps
   through the app-group access group.
4. Until step 1 exists every CloudKit call fails softly by design: the row
   simply never appears, and nothing else changes.
