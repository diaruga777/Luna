# Vault UI and flow audit — September 2026

The active iPhone surface is `VaultSyncthingHomeViewController`, composed by
`VaultConnectedWiring`. Legacy `VaultRootViewController` and its device/iCloud
setup screens are not the active app and were not redesigned in this pass.

## Library

- Native large-title navigation, system glass controls, and `UISearchController`.
  iOS chooses the search bar placement. No custom glass backgrounds or animations.
- First launch offers **Connect Mac**, with no empty Recent/Results sections or
  import action that cannot succeed before pairing.
- Connected/offline libraries show the Mac connection, folder browsing, and
  reusable file rows with type symbols, dates, and sizes. Offline wording makes
  clear that downloaded files remain available.
- Search is debounced and cancellable. Late responses cannot replace a newer
  query. Foreground connection polling does not restart searches, clear results,
  or dismiss the keyboard. Search describes the supported names/content behavior,
  not the old unimplemented date-search promise.
- Folder browsing sorts folders first, offers name/date sorting, and distinguishes
  empty folders from load failures with an explicit retry action.
- Standard self-sizing UIKit content supports Dynamic Type, VoiceOver, light/dark
  appearances, and system navigation/motion preferences.

## Connection and maintenance

Setup explains three steps: open the Mac app on the same network, paste its code,
then approve on the Mac. The Connect action stays disabled for empty input and
shows progress during verification. Errors remain beside the field; network
settings are offered for permission failures, not malformed codes. Successful
pairing returns to the library. A pairing deep link or **Update Connection** opens
setup even for an already paired Mac.

Paired settings separates connection, downloaded storage, search maintenance,
and disconnect. Removal actions require an explanation and confirmation.
Disconnecting or changing to another Mac is blocked while local changes await
upload, because removing/replacing the peer clears the mirror's local-change rows.

File opening presents delayed, cancellable progress for slow preparation; cached
files avoid a flashing progress sheet. Quick Look is presented from the visible
folder. Large preview copies run off the main actor, and temporary plaintext
preview copies are removed when Quick Look closes. The add menu offers separate
file, folder, Photos, and album pickers. Folder import retains nested paths and empty folders.
The import sheet covers local preparation, then closes so Home can show each
pending file in Transfers with bytes sent,
total bytes, and a progress bar; reaching the byte total means Vault is waiting
for the Mac to save and confirm it. A pending file or folder can be cancelled from
that row. Recent, search, and folder rows offer swipe to delete, with confirmation.
Deletion remains pending until the Mac acknowledges it; the same name cannot be
reimported before that acknowledgement. Import errors appear after the document
picker has dismissed.

The share extension copies multiple files into the App Group inbox before it
reports that they are queued. It submits an iOS 26 continued processing request,
which Vault handles with a system Live Activity showing transfer progress.
The Files and Photos pickers use the same queue. Individual Photos are stored
under `Photos/`; an album creates `Photos/<album>/` on the Mac. iOS may postpone
or expire a background request, so queued payloads and local changes survive
app termination and resume on a later foreground or processing wake. Home shows
the number of files still in the inbox alongside the Mac's pending transfers.

## Icon

`Design/IconComposer/Luna Vault.icon` uses the exact Reader `Group 9.svg` moon and
`Polygon 1.svg` curved foreground, including their layer placement and glass
settings. A blue palette and original lock silhouette distinguish Vault.
The rendered icon and 96/192/288-point design-system images replace the old artwork.

Regenerate with Xcode 27 Icon Composer (the family documents use its schema):

```sh
"/Applications/Xcode-27.0.0-Beta.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  "Design/IconComposer/Luna Vault.icon" --export-image --output-file /tmp/vault-icon.png \
  --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
swift scripts/export_vault_icon.swift /tmp/vault-icon.png .
```

Like the other shipping Luna icons, the app consumes a flattened opaque app-icon
asset. The editable source retains the real Icon Composer materials. The export
helper only supplies the full-square background outside the system icon mask and
creates the smaller in-app images; it does not redraw the moon or glass artwork.

## Verification

`VaultVisualFlowTests` covers first-run gating, native browsing and folder errors,
search cancellation, query preservation on refresh, empty connected libraries,
and scrollable setup at accessibility text sizes. Its XCTest attachments capture
light/dark libraries, search, setup, connected settings, and large-text states.

`LunaVaultConnectionTests` verifies real loopback TLS pairing/download/upload,
per-file transfer progress, block timeouts, resumable Mac uploads, cancellation,
and nested Photos album paths. `VaultIncomingQueueTests` verifies ordered App
Group handoff survives reopening its store.
Continued processing requests now use the exact registered identifier: the
share extension submits one static queue task handled by the containing app,
while in-app imports register their unique task immediately before submitting.
An idle transfer ends its Live Activity and keeps unsent files durable for retry.
Its separate
scheme avoids the legacy app-hosted test bundle's duplicate package type linkage.
Live user-Mac pairing, Files-provider UI, and physical-device animation performance
are not implied by these automated checks.
