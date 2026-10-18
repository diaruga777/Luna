# Luna Premium

`LunaPremium` is the shared StoreKit 2 access service for all Luna apps.
Core Luna owns `com.hsanabria.luna.premium`, a one-time non-consumable.
App Store Connect app 6800900997 / IAP 6824195803 is configured at exactly
USD 2.00, with Apple's equivalent prices and availability in all current and
future territories. Its review screenshot is uploaded and its current ASC state
is `READY_TO_SUBMIT`. The product still needs Apple's review before production
purchases are available. No app was uploaded or submitted by this change.

Plugin creation opens a sheet with Apple's localized `Product.displayPrice`,
Restore purchases and a smaller “Unlock without paying” button. It gates every
creation entry point, including failed-save and Safari handoffs. Purchase
cancellation, pending approval and verification failure never grant access.
A missing product offers retry and the free route instead of a fabricated price.

“Unlock without paying” shows the requested Premium features confirmation.
Continue for free sets only `PremiumAccessState.freeForThisLaunch`. It is not
written to defaults, keychain, files or iCloud; another app process or a new
launch asks again. Cancel leaves access locked. Importing and exporting plugins
and running already installed plugins are not premium features.

Paid access is recorded only after a StoreKit-verified transaction and read
through the shared App Group by every Luna app. Core rechecks current entitlements
on launch, foreground and transaction updates, clearing shared paid access on
revocation/refund. Other apps do not erase the record merely because their own
receipts lack core Luna's product. On another device, open core Luna and Restore
purchases to populate that device's shared App Group. Sibling apps cannot restore
a different app's IAP directly; this design does not operate an account server.
