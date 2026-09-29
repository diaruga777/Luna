# Vault UI and flow audit — September 2026

The active iPhone surface is `VaultSyncthingHomeViewController`, composed by
`VaultConnectedWiring`. Legacy `VaultRootViewController` and its device/iCloud
setup screens are not the active app and were not redesigned in this pass.

## Browser

- Native large-title navigation, system glass controls, and `UISearchController`.
  iOS chooses the search bar placement. No custom glass backgrounds or animations.
- First launch offers **Connect Mac**, with no empty Recent/Results sections or
  import action that cannot succeed before pairing.
- Connected/offline libraries show the Mac connection, Mac Files, Vault Folder, Downloads, a Transfers activity row, and
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
Photos export formats, and disconnect. Images default to JPEG and videos to
MP4; each can be changed independently to Original. Both the individual picker
and album import use the saved choice. Removal actions require an explanation and confirmation.
Disconnecting or changing to another Mac is blocked while local changes await
upload, because removing/replacing the peer clears the mirror's local-change rows.

File opening presents delayed, cancellable progress for slow preparation; cached
files avoid a flashing progress sheet. Quick Look is presented from the visible
folder. Large preview copies run off the main actor, and temporary plaintext
preview copies are removed when Quick Look closes. The add menu offers separate
file, folder, Photos, and album pickers. Folder import retains nested paths and empty folders.
Opening waits for the Mac's current index before requesting blocks and retries
once on a stale or failed block connection. The sheet labels the transfer as a
download from the Mac and Cancel stops the in-flight request. Quick Look uses a
hard link to the downloaded cache when possible, avoiding another full copy of
large files.
The import sheet covers local preparation, then closes so the dedicated Transfers screen can show each
pending file with bytes sent,
total bytes, and a progress bar; reaching the byte total means Vault is waiting
for the Mac to save and confirm it. A pending file or folder can be cancelled from
that row. Vault root, search, and folder rows offer swipe to delete, with confirmation.
Deletion remains pending until the Mac acknowledges it; the same name cannot be
reimported before that acknowledgement. Import errors appear after the document
picker has dismissed.

The share extension copies multiple files into the App Group inbox before it
reports that they are queued. It submits an iOS 26 continued processing request,
which Vault handles with a system Live Activity showing transfer progress.
The Files and Photos pickers use the same queue. Individual Photos are stored
under `Photos/`; an album creates `Photos/<album>/` on the Mac.
Already matching JPEG and MP4 files keep their original bytes; other media is
converted on disk before queuing, so large videos are not loaded into memory.
The Original setting preserves the Photos resource format. iOS may postpone
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
multiblock Mac pulls, photo format settings persistence, per-file transfer
progress, block timeouts, resumable Mac uploads, cancellation,
and nested Photos album paths. `VaultIncomingQueueTests` verifies ordered App
Group handoff survives reopening its store.
`VaultPhotoFormatTests` checks PNG to JPEG and MOV to MP4 conversion plus the
Original choices without requesting Photos access.
Continued processing requests now use the exact registered identifier: the
share extension submits one static queue task handled by the containing app,
while in-app imports register their unique task immediately before submitting.
An idle transfer ends its Live Activity and keeps unsent files durable for retry.
Its separate
scheme avoids the legacy app-hosted test bundle's duplicate package type linkage.
Live user-Mac pairing, Files-provider UI, and physical-device animation performance
are not implied by these automated checks.

## Polish pass — 28 September 2026

- Native Liquid Glass buttons for Connect Mac, the empty-library import action,
  and per-file transfer cancellation. System navigation and search retain their
  standard appearance. Transfer buttons have 44-point touch targets and separate
  VoiceOver labels; progress text supports Dynamic Type.
- Downloads opens a local-only list without waiting for the Mac. File rows show
  Downloaded or On Mac. Downloads has no destructive Mac-file swipe action;
  Remove Downloads remains in Settings.
- Byte-only progress changes update visible transfer cells in place. They retain
  the import menu, scroll position, and focus. Recent files use SQLite's limit;
  searches scan cancellable 256-record pages instead of loading every record.
- Cancel propagates to detached import/preview preparation. Incoming file copies
  use 1-MB chunks with cancellation checks and publish only complete payloads.
  Folder intake skips symbolic links. Previously queued files remain durable.
- Peer block metadata is checked for contiguous offsets, valid lengths and hashes,
  and agreement with file size before transfer. Invalid index batches roll back.

Validation: 30 connection tests and 11 UI/intake tests on iOS 26.2; UI attachments
cover light/dark, setup, offline downloads, empty states, and accessibility text.
Physical-device throughput and live user-Mac pairing were not measured in this pass.

## Mac file browser — 29 September 2026

Browse leads with locations and the Vault root, sorted folders first. Uploads
have their own Transfers screen with byte progress, queued preparation, waiting
for Mac confirmation, offline states, and cancellation. Progress updates change
visible cells in place. The Browse activity row shows the pending count.

Mac Files has Home, Desktop, Documents, Downloads, Macintosh HD (`/`), and Volumes.
Folder screens show their path, date/size rows, name/date sorting, paging,
pull-to-refresh, Show Hidden Files, and Go to Folder. These screens have no
upload or delete action, including when navigating into the Vault via Mac Files.
Open downloads a temporary file for Quick Look and sharing. The existing Vault
Folder surface retains indexing, durable downloads, imports, and deletion.
Search explicitly says “Search Vault files and contents.”

Permissions, a missing disk/folder, and an outdated companion produce explicit
errors with retry. First-run setup and the Mac’s pairing explanation describe
the read-only Mac scope and the writable Vault folder.
