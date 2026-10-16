# One Luna Mac connection

Vault, Music, and Code use `LunaMacConnection.makeRuntime` as their sole production
composition point. They share the Luna Mac companion, the authenticated TLS/BEP
protocol, the App Group pairing store, and one account identity. A Mac trusts one
certificate identity at a time; simultaneous sessions from multiple apps and
physical devices using that identity are allowed (up to eight sockets). A different
identity cannot replace it by opening the pairing window. **Forget Luna connection**
on the Mac revokes live sessions and clears the configured app list before another
identity can pair. Existing Mac identity, trusted-device preference, and folder paths
are preserved on upgrade.

## iPhone and iPad UX

`LunaMacConnectionViewController` owns setup, connection status, reconnect, update,
and disconnect for all three apps. Its app descriptor (`LunaMacClient`) supplies
the containing app’s name and short introduction. Vault adds its download, search,
and Photos export settings; Music and Code do not display those controls.
`VaultConnectedSettingsViewController` remains a compatibility alias.

`LunaMacLaunchViewController` gives each app a first-launch flow, including an
explicit **Already connected** state and **Continue to Luna …** action when another
app or device has set up the Mac. Saved pairing is distinct from online reachability:
a restored but unavailable Mac shows Offline and Reconnect. Music additionally
allows **Not Now** so Apple Music and podcasts remain usable without a Mac. Each
app remembers completion separately. Music defers foreground library search and
its media permission prompt until Continue or Not Now, retaining pending routes. Connection settings remain available later.
The visible connection screen checks for newly synchronized credentials every two
seconds without resetting a pairing-code field while typing. App foreground work
also restores credentials and reconnects; Code and Music service requests check
credentials before using an existing socket.

## Credentials and iCloud

`LunaMacKeychain` stores a single versioned, synchronizable generic-password item
in `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_PREFIX).mac.connection`, entitled only to
the three host apps. It uses `kSecAttrSynchronizable` and
`kSecAttrAccessibleAfterFirstUnlock`, not a `ThisDeviceOnly` accessibility class.
The atomic value contains the TLS certificate, private key, verified Mac identity,
addresses, and folder descriptor. Credentials are never put in preferences or
public CloudKit records. Another physical device obtains the same certificate and
private key and therefore authenticates as the same client to the Mac.

Users must enable **iCloud Passwords & Keychain** on both devices under the same
Apple Account. Delivery is eventual; there is no promise of immediate restoration.
The setup screen explains this and updates when the item arrives. Local pairing
continues to work when Keychain sync is disabled. A second device must wait for the
approved identity to sync; creating an unrelated local identity cannot replace the
Mac’s existing trust. The Mac authenticates possession of the certificate’s private
key, rather than independently inspecting or attesting an Apple Account.

Only a pairing verified against the Mac’s initial index can be published. Existing
verified local pairings migrate on upgrade. A synchronized identity that arrives
during pairing cannot be overwritten by that pairing. A synchronized nil pairing
is an explicit disconnect tombstone, retaining the account identity so it can pair
again. Disconnect explains that it affects all Luna apps and Keychain-connected
devices. Pending local uploads prevent removal/replacement on the device that
holds them. Index cursors, random local index IDs, file mirrors, downloads, drafts,
and pending uploads never sync as credentials.

`LunaMacIdentityStore` materializes a restored key in an owner-only directory named
by its certificate fingerprint, with iOS file protection. This avoids changing a
certificate cached by the Go transport at an existing path. Initial certificate
creation takes a filesystem lock across app processes. The runtime can replace its
session identity when credentials arrive while the app is running. A disconnect
also stops old sessions when another app has already removed the shared SQLite row.

## Adaptive Mac UI

Each production client sends a versioned `luna-client-v1` startup request inside the
approved BEP stream on first connection and after reconnect. The companion refuses
startup messages before approval, malformed versions, and messages after revocation.
The authenticated client descriptor, not discovery names, enables its Mac section.
Configured apps persist across companion restarts, and their sections remain visible
while offline. Vault exposes file sync details; Music exposes its library folder;
Code exposes editing/build details. The folder chooser appears only for Vault or
Music. CodeService is created lazily when a Code request arrives.

## Verification

`LunaVaultConnectionTests` covers real loopback TLS with two independent device
stores restoring one identity, concurrent Vault/Music/Code announcements, rejection
of an unrelated identity, synchronized disconnect, credentials arriving during a
running session, cursor preservation, unverified-pairing rejection, stale Mac
approval rejection, and each app’s first-launch restored UI. Cloud delivery itself
requires two signed physical devices using one Apple Account with Passwords &
Keychain enabled; deterministic tests use an injected credential store and do not
claim to verify Apple’s synchronization service.

## Folder permission recovery

The companion uses `CompanionFileAccess` before Code operations, Mac file browsing,
Music requests and Vault folder setup/scanning. Read-only probes run off service
actors and return an error after eight seconds when folder access stalls. macOS
has no public API that confirms a pending Files and Folders prompt, so the message
says access is taking too long and asks the user to check for a system prompt.
A denied probe explicitly directs the user to Privacy & Security → Files and
Folders / Full Disk Access. Luna Mac shows the affected path and offers an Open
Privacy & Security button. The listener starts before protected-folder setup,
so initial connection failures can carry the same actionable error to iOS.

Retry reuses a still-blocked probe rather than creating more filesystem calls.
After the prompt is answered, another request can proceed. Probes never write;
a timed-out save preflight cannot later resume a write. Failed directory scans
also leave the previous Vault index intact instead of treating unreadable files
as deletions. Tests inject stalled reads and denials; they do not automate or
change the user's macOS privacy permissions.
