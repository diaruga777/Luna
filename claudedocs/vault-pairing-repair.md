# Verified Mac pairing and active app runtime

The iPhone composition root is `VaultConnectedWiring`. It constructs one
`VaultFolderStore`, Go TLS identity, `VaultSyncSession`, and
`VaultConnectedRuntime` shared by home, settings, import, and preview.
The retired `VaultWiring` and capsule credential screens remain compiled for
legacy tests but are not app entry points. Existing legacy storage is not
removed or migrated implicitly.

## Pairing

The companion's Copy pairing code button produces one `luna-vault://pair`
value containing its certificate device ID and direct LAN/Tailscale interface
addresses. Vault listens on its own port 49200, falling back to an available
system-assigned port if occupied; it does not compete with Syncthing on 22000.
Wildcard bind addresses are excluded. The phone verifies the exact
certificate ID; addresses are routing hints, not authentication. A separately
installed Tailscale client can route those TCP addresses. The active app does
not start an embedded tsnet node.

The companion allows new pairing attempts for five minutes after launch or
Copy pairing code. An unknown phone receives no folder or file access until
the Mac user clicks Accept. The accepted device ID persists across restarts.
Only one phone is authorized at a time. The SwiftPM GUI explicitly constructs
and retains its `NSApplicationDelegate`; a nibless `NSApplicationMain` alone
can leave a process running without starting the companion listener. Both directions exchange BEP Hellos,
ClusterConfig, and an initial index. The folder config must explicitly include
the phone's identity. A completed socket write alone never marks the session
connected.

The phone first verifies the candidate in an isolated temporary mirror. A
failed attempt cannot replace the existing peer or wipe its pending imports.
It then saves the verified peer and connects the durable mirror before showing
success. Settings and home read this same store. Old peer rows written by the
unfinished code-only screen have no `lastConnectedAt` and are not shown as
verified or automatically reconnected. Paste a fresh code to finish pairing.
A previously verified Mac remains paired when temporarily offline.

## iPhone network permission

Before the Go TLS dial, production iPhone TCP connections use a bounded
Network.framework check. This participates in iOS Local Network consent,
waits for the user to allow access, and reports `localNetworkDenied` distinctly
instead of reducing it to BSD's “no route to host”. Settings presents a link
to iPhone Settings for permission failures. Permission denial stops the attempt; it does
not erase the previous pairing. Other unreachable routes still receive a
clear Wi-Fi/Tailscale diagnostic. The pinned TLS handshake remains mandatory
after this reachability check.

## Files and reconnect

The Mac retains each active connection and its delegate, scans the folder on
connect, and checks for changes every five seconds while connected. The phone
reconnects when foregrounded and checks its connection every sixty seconds;
pull to refresh forces a new index exchange. Returning from Settings reloads
home from the same durable mirror. File previews fetch verified blocks and
use the bounded local cache. Imports are announced durably; the Mac downloads
and checks every block, installs the file, and only then acknowledges it in
its index. Different existing Mac files are never overwritten by an import.
Mac symlinks are excluded from scans and cannot escape the shared root when
serving blocks.

The active UI supports browse, search, previews, import, and cache clearing.
It does not expose deletion or editing. Mac-side tombstone/conflict handling,
public relay/discovery publication, and legacy share-extension migration
remain separate work; this repair does not claim those paths are complete.
If a copied direct address changes, copy a fresh code from the Mac. The
companion currently rescans rather than using FSEvents.

## Run and verify

`script/build_and_run.sh --verify` builds the actual `LunaVaultTailscale`
companion product, stages a signed local app bundle, and launches it. The
Codex Run action already points to this script.

`LunaVaultConnectionTests` is a standalone simulator test scheme. It avoids
the legacy app-hosted bundle's duplicate Swift package types and never touches
a user folder or starts cloud discovery. Its tests use real Go TLS loopback
sockets with the production companion delegate and verify pairing, byte-exact
download, acknowledged upload, store reopen/reconnect, wrong-certificate
rejection, offline rollback, old false-pairing rows, initial-index gating,
and bounded Hello timeout.

```sh
xcodebuild test -project Luna.xcodeproj -scheme LunaVaultConnectionTests \
  -destination 'platform=iOS Simulator,id=<simulator UDID>'
```

The active UI flows and icon sources are documented in [vault-ui.md](vault-ui.md).

## Shared Luna Code companion

The companion now displays **Luna Mac**, retaining Vault’s identity, pairing and
state paths. Luna Code uses the same approved BEP connection for explicit text
edits, SourceKit checks and Mac build/TestFlight commands. Concurrent Code and
Vault sessions are supported. See [Luna Code](code.md) for the additional scope.
