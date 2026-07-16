# Luna Interoperability purchase

Luna's three apps share one reading-list store, but each app owns one kind of
saved content. A one-time **Luna Interoperability** purchase allows a user to
save a link in one Luna app when the classified result belongs to another.
Without the unlock, the user can always share the link directly to its owning
app. The gate controls cross-app writes; it does not hide already-saved items.

## Ownership and decision

`Outcome.interopOwner` is the single ownership mapping:

| Classified outcome | Owning app |
| --- | --- |
| article or document | Luna Reader |
| social/video/audio media | Luna Downloader |
| product price tracker | Luna Price Tracker |
| failed/unclassified | none (never gated) |

`InteropGate` makes the decision before a write:

| Situation | Result |
| --- | --- |
| Outcome belongs to the current app, or has no owner | Save normally |
| Cross-app and unlocked; owner installed | Save normally |
| Cross-app and unlocked; owner not installed | Save, then explain which app to install |
| Cross-app and locked | Save nothing and offer the unlock/direct-share alternative |

The installed-app check uses best-effort App Group markers
(`lunaInstalled.reader`, `.downloader`, and `.pricetracker`). A marker can
outlive an uninstall, so it only controls explanatory UI; it is never treated
as purchase evidence.

## Which saves are gated

Share/action extensions, paste/manual saves, and the Save App Intent are gated.
Incoming email and friend-share ingestion are intentionally exempt: these are
background/universal delivery paths and continue filing content into the shared
store regardless of payment.

The gate runs after classification but before outcome presentation or any
surface-owned mutation. A blocked placeholder is deleted along with copied
document files. `ingestAllPending()` uses the same gate without presenting UI,
so a leftover blocked placeholder is silently cleaned up during a background
sweep. Interactive in-app saves show `InteropPromptViewController` and retry
after a successful inline purchase. Price Tracker's seller-accept and "Read
instead" actions gate before changing the tracker, preventing a blocked action
from partially mutating or deleting it.

Extensions cannot purchase. Their prompt opens the containing app using
`<ownScheme>://interop` and always displays a manual Settings fallback. The
SceneDelegate routes this URL to `InteropPaywallViewController`; when it arrives
during first-launch onboarding, the route remains queued until the main
navigation controller exists. App Intents cannot present UIKit, so a blocked
save returns an error dialog and a paid save whose owner is missing returns a
successful "install Luna …" dialog.

## Purchase and shared entitlement

Each app sells its own non-consumable product:

- `com.hsanabria.luna.reader.interop`
- `com.hsanabria.luna.downloader.interop`
- `com.hsanabria.luna.pricetracker.interop`

More generally the id is `<bundle identifier>.interop`; namespace changes in
`Config/Luna.xcconfig` therefore carry through. The App Store price is loaded
from StoreKit (the planned tier is USD 1.99).

A verified transaction for the running app's product records the shared App
Group boolean `interop.unlocked`. Every Luna app and extension trusts that one
flag, so buying once unlocks cross-app saving across the family on that device.
`Transaction.updates` is observed at launch and current entitlements are swept
to recover transactions delivered while the app was not running.

The products belong to separate App Store Connect app records. Consequently,
Restore can only find a purchase in the Luna app where it was originally made;
the paywall states this explicitly. Restoring there rewrites the shared flag for
the sibling apps. Debug and TestFlight builds grant paid features without a
purchase and label the reason in the paywall rather than implying a transaction.

## User entry points

Every app's Settings screen contains **Luna Interoperability**. It displays
**Unlocked** when the shared entitlement or build grant is active and opens the
same paywall used by the deep link. The paywall shows the live price, Buy,
Restore, the restore caveat, and the current unlocked state.

## Regression coverage

The focused tests are `InteropSurfaceTests`, `InteropGateTests`,
`InteropEntitlementTests`, `InteropPurchaseControllerTests`,
`ShareSurfaceDriverInteropTests`, `ReadingListIngestorInteropTests`, and the
interop cases in `LunaDeepLinkTests`. Keep the source-exemption matrix and the
"blocked means nothing remains" invariant explicit when adding a capture source
or a new direct-write path.
