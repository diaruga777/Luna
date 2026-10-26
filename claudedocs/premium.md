# Luna Premium

`LunaPremium` is the shared StoreKit 2 access service for all Luna apps.
Luna Reader owns two one-time non-consumables in App Store Connect app
6800900997. Both unlock the same Premium features across Luna apps:

| Product | ASC IAP | US price |
| --- | --- | --- |
| `com.hsanabria.luna.premium` | 6824195803 | $2.00 |
| `com.hsanabria.luna.premium.happyhour` | 6827067768 | $1.49 |

Both products are configured, have review screenshots, and are `READY_TO_SUBMIT`. They still need
Apple's review before production purchases are available. No app build or
purchase was submitted for review as part of the happy hour change.

Plugin creation opens a sheet with Apple's localized `Product.displayPrice`,
Restore purchases and a smaller “Unlock without paying” button. It gates every
creation entry point, including failed-save and Safari handoffs. Purchase
cancellation, pending approval and verification failure never grant access.
A missing product offers retry and the free route instead of a fabricated price.

“Unlock without paying” shows the Premium features confirmation. Continue for
free sets only `PremiumAccessState.freeForThisLaunch`. It is not written to
defaults, keychain, files or iCloud; another app process or a new launch asks
again. Cancel leaves access locked. Importing and exporting plugins and running
already installed plugins are not premium features. The purchase sheet can
still be opened from a reminder after choosing free access for this launch.

## Happy hour

On **Saturday and Sunday, 14:00 inclusive to 15:00 exclusive**, using the
user's current local time zone, the purchase screen selects the happy hour
product. It shows a small discount tag, the weekend schedule, and the sale and
regular localized prices while the offer is active. It updates while open and
reloads products on foreground. A purchase rechecks the window after preparing
StoreKit and checking entitlements. If the selected SKU changed since the tap,
it asks the user to check the updated price and tap again; it never silently
falls back to a full-price purchase. An Apple purchase sheet or pending approval
already started during the window may complete later.

Apple's [promotional purchase option](https://developer.apple.com/documentation/storekit/product/purchaseoption/promotionaloffer(offerid:signature:))
is for auto-renewable subscriptions. Its
[IAP price schedules](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/schedule-price-changes-for-in-app-purchases/)
use calendar dates, so a separate non-consumable with app-side time gating is
used for this hourly offer. There is no server or subscription. The discount
product is not promoted on the App Store. Its availability stays enabled in ASC;
the app controls when to offer it. Local device time is intentionally the
eligibility source, rather than a server-enforced anti-abuse mechanism.

Apple price tiers do not always allow exactly 25% off ($1.50 is unavailable in
the US). The screen says **“25% off or more.”** On 2026-10-26, the happy hour
product was explicitly priced in all 175 territories at the highest positive
available tier no greater than 75% of the regular product's effective price.
Examples: USD 2.00 → 1.49, AUD 3.00 → 2.19, NZD 4.00 → 3.00,
KRW 3,300 → 2,400. Availability includes future territories. These manual prices
need review if regular prices change or Apple adds territories. At runtime,
StoreKit prices must use the same currency and save at least 25%; otherwise
the discounted purchase is unavailable and the sheet offers retry or free
access. The app never fabricates a localized discount or charges full price
while showing a happy hour offer.

## Local reminders

“Remind me at 2 pm” explicitly requests notification permission, then schedules
two repeating `UNCalendarNotificationTrigger`s: Saturday and Sunday at 14:00.
No fixed time zone is embedded, so the reminders follow local wall-clock time.
They use stable request identifiers, do not duplicate, and can be turned off
from the same sheet. Denied permission offers a Settings link; scheduling
failure removes both requests so the UI never reports a partial schedule as
complete. Delivery is subject to iOS notification settings and Focus.

Tapping a reminder routes to `<own scheme>://premium`, opening the purchase
sheet on cold or warm launch without requiring plugin creation. Successful
purchase, restore, or discovery of an existing paid entitlement cancels the
pending and delivered reminders. Free access does not cancel an explicit
reminder opt-in.

## Shared entitlement

Paid access is recorded only after a StoreKit-verified transaction and read
through the shared App Group by every Luna app. The durable record keeps the
canonical `.premium` entitlement ID for compatibility with older companion
apps and records the actual purchased SKU separately. Luna Reader rechecks
current entitlements for **both** products on launch, foreground and transaction
updates. Refunding one SKU does not remove access if the other is still owned.
Existing owners cannot buy the other SKU through the purchase service.

Other apps do not erase the record merely because their own receipts lack Luna
Reader's products. On another device, open Luna Reader and Restore purchases
to populate that device's shared App Group. Sibling apps cannot restore a
different app's IAP directly; this design does not operate an account server.

## Validation

The happy hour change passes 29 targeted iOS 26.2 simulator tests covering
StoreKit purchases and restoration, time boundaries and time zones, refunds,
shared entitlement compatibility, notification scheduling and permission denial,
the purchase screen, and localization keys. The live simulator permission,
reminder enable/disable controls, and `luna://premium` route were also checked.
