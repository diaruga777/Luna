# Luna Vault Mac companion (v1 foundation)

The Mac storage option is a companion process owned and installed by the user.
Luna has no hosted relay or cloud bucket. Since 2026-08 the Vault app and the
companion EMBED Tailscale (tsnet, via the `LunaVaultTailscale` package —
vendored TailscaleKit wrapper over a committed `LibTailscale.xcframework`):
neither device needs the Tailscale app installed. Each side runs its own
userspace tailnet node; the user authorizes each node once through the SDK's
interactive web-auth flow (the control plane's `browseToURL`, opened in
`SFSafariViewController` on the iPhone and in the default browser by the
companion). Vault dials the companion's MagicDNS `*.ts.net` name, Tailscale
CGNAT address, or Tailscale IPv6 address. Tailscale chooses the path: a direct
peer path when available, or a DERP relay when it is not. Luna cannot promise
that a connection is direct. On the same LAN, the companion can also publish
`_lunavault._tcp` and the iPhone-side browser can discover it; manual `.local`
entry remains a fallback that bypasses the embedded node entirely
(`VaultTailscaleMacConnector` routes `.tailscale` endpoints through tsnet and
`.lanBonjour` endpoints through the direct Network-framework path).

## Embedded tailnet lifecycle

The iPhone side owns one lazy `VaultTailnetNodeRunner` per process
(state under Application Support/LunaVault/Tailscale, hostname
`luna-vault-iphone`). Nothing starts the node until the Settings → Mac screen
or a `.tailscale` dial needs it. Dialing NEVER triggers interactive auth: it
gates on a Luna-owned "login completed" marker in the state directory (set on
first `.running`, cleared on logout) rather than on the directory being
non-empty — tsnet writes state as soon as a node ever starts, including a
login the user cancelled partway through, so the marker is what tells a
completed login apart from an abandoned one. A node that fails the gate never
starts; a dial against it fails closed with `needsLogin`, and sync reports an
honest unavailable state. Connecting and logging out live on the Settings →
Mac screen ("Tailscale routing" section), which drives
`VaultTailnetControlling` — a protocol witness in LunaVaultBackend, so the UI
never imports the Tailscale package.

`tailscale_up` ignores task cancellation, so a 45 s timeout has to interrupt
it rather than cancel it: `tailscale_close` is the documented cross-thread
interrupt. `up()`, `close()`, and the new `interrupt()` on `TailscaleNode` are
`nonisolated` and every call runs through `VaultTailnetNodeRunner`'s own
concurrent dispatch queue (`runBlocking`) rather than the actor's executor —
so a timed-out `up()` and the interrupt that unblocks it run on two different
threads instead of the interrupt queuing behind the very call it needs to
stop. A `closeOnce` guard on `TailscaleNode` keeps `tailscale_close` to
exactly one call across `interrupt()`, an explicit `close()`, and `deinit`.
The next dial attempt recreates the node from persisted state.

The companion (`LunaVaultMacCompanion`, now an executable of the
`LunaVaultTailscale` package) runs its own node with
`--tailscale-state <dir> [--tailscale-hostname <name>] [--tailscale-port <port>]`.
On first run it prints and opens the web-auth URL, then prints the endpoint
binding to paste into `--initialize` (`tailscale:<magicdns>:<port>`). It
listens on the tailnet through tsnet and can ALSO keep the direct
`--bind-host` listener; both transports share one `VaultMacConnectionGate`, so
the connection and failure budgets hold for the process as a whole. The serve
loop is transport-neutral (`VaultMacChannelServer` in LunaVaultMac); both
listeners hand it authenticated frame channels. A single `tailscale_accept`
failure retries with exponential backoff (capped at 30 s) inside
`VaultTailnetListener.connections()` instead of ending the stream — a
sibling `--bind-host` LAN listener stays up through a transient tailnet
accept hiccup instead of the companion exiting and tearing both down.

The wire format over tsnet is identical to the LAN path: a 4-byte big-endian
length prefix per frame (`VaultTailscaleFrameChannel` mirrors
`VaultMacNWFrameChannel`; `VaultTailscaleTransportTests` pins the parity over
a socketpair). Everything above the channel — pairing, challenge handshake,
AES-GCM sealing, replay guards — is unchanged and stays independent of
Tailscale. `VaultTailscaleFrameChannel.init` sets `SO_NOSIGPIPE` on the raw
descriptor (dial and accept both construct the channel only there), so a peer
disconnecting mid-send surfaces as the channel's own `.unavailable` error
through `send()`'s errno path instead of SIGPIPE terminating the process.

## Debugging on a real device

Every layer logs to the unified log under one subsystem. Attach the iPhone
and run:

```sh
log stream --device --level debug \
  --predicate 'subsystem == "com.hsanabria.luna.vault"'
# or capture after the fact: log collect --device --last 30m
```

Categories: `tailnet` (node lifecycle, login flow, dials with timings),
`tailnet-channel` (per-frame traffic and socket errors), `tailnet-listener`
(companion accepts), `tsnet-go` (the Go engine's own log, relayed through a
pipe pump — handshakes, DERP/direct path selection, netmap), `mac-client`
(session auth, uploads/downloads with byte counts, per-request failures and
timeouts), `mac-server` (companion sessions, per-request statuses, gate
rejections). Logs carry operations, statuses, byte counts, and endpoint
hosts — never key material, ciphertext, or pairing secrets. The companion
additionally prints lifecycle and per-connection lines to stdout with the
same information.

Two log paths inside tsnet: the spammy engine log goes through the fd Luna
hands it (the `tsnet-go` category), while tsnet's few "user-facing" notices —
including its own copy of the login URL — go to the process stderr (visible
in Xcode's console when attached, and in the companion's terminal). The login
URL Luna acts on always comes from the IPN bus, not from parsing logs;
verified against the live control plane 2026-08-31.

## Pairing and channel security

Pairing is application-level and independent of Tailscale:

1. The Mac creates a five-minute, one-use offer containing a random pairing ID,
   nonce, endpoint binding, and server identity binding. The setup UI must show
   the server-binding fingerprint out of band for the user to compare on both
   devices.
2. The iPhone proves possession of the one-time setup code. The Mac accepts the
   enrollment only once, only before expiry, and only after the fingerprint
   confirmation seam approves it.
3. Both sides derive a 32-byte paired credential. The Mac stores that credential
   in an owner-only file; it never receives the Vault root encryption key.
   Pairing credentials carry an epoch and support explicit rotation/revocation.
   A rotation re-encrypts the companion manifest under the replacement secret;
   the caller then persists the replacement credential and recreates the
   listener. Revocation terminates active listener sessions at their next
   frame boundary.
4. Every TCP connection begins with a fresh, short-lived server challenge and a
   client proof bound to the pairing ID, credential epoch, endpoint, server
   identity, both nonces, and a unique session ID. The server consumes session
   IDs once and rejects an old transcript on a new connection.
5. HKDF derives independent request and response keys. Request and response JSON
   is sealed with AES-GCM; the visible envelope contains only protocol version,
   session ID, direction, contiguous sequence number, nonce, ciphertext, and
   tag. The nonce and authenticated data bind direction and sequence. Replays,
   gaps, reflected frames, changed ciphertext, and changed tags are rejected.

This is application-layer authenticated encryption and channel binding, not
TLS certificate pinning. It protects content and request metadata from the LAN,
Tailscale path, and DERP. The out-of-band fingerprint comparison is mandatory in
the eventual setup UI; silently accepting a first-seen identity would permit an
active first-pairing attack.

## Storage and transfer contract

The iPhone-side `VaultMacRemoteBackend` implements `VaultBackendTransport` over
fresh authenticated sessions. It accepts only strict Tailscale/MagicDNS or
Bonjour endpoint shapes. The shared contract supports:

- opaque UUID object IDs and client-generated total-order revisions;
- client-side-encrypted object bytes and encrypted higher-level metadata only;
- chunked, resumable and idempotent writes, bounded to 100 GiB per object and
  65,536 chunks (the client’s 4 MiB transfer size needs at most about 25,600
  chunks at the object limit);
- exact bounded range reads; and
- revision-checked tombstones that allow a legitimate newer replacement.

An idempotency record covers the operation, object, revision, chunk/range
coordinates, declared length, and body hash through a canonical request digest,
and stores the exact response. Reusing a key with any changed field is a
conflict. The companion validates revision, shape, partial-count, and quota
before writing a chunk.

The encrypted manifest is limited to 16 MiB by default. The store defaults to a
1 TiB total quota and 64 concurrent partial uploads. Directories are mode 0700,
files are 0600, file descriptors use no-follow/exclusive creation, completed
files and manifests are fsynced before atomic rename, and parent directories are
fsynced afterward. Startup recovery removes staging files, stale partials,
unreferenced revisions, and symlinks without following them. Deletes and
replacement commits similarly prune obsolete ciphertext after the manifest is
durable.

The listener cannot start without an already-paired, non-revoked credential and
a concrete non-wildcard bind host. It bounds concurrent connections, handshake
time, idle time, and per-peer/global authentication failures. Bonjour publication
and browsing are explicit seams (the browser receives the companion's advertised
port); no discovery result bypasses fingerprint or session authentication.

## Threat model and operational limits

The network path may observe endpoints, timing, packet sizes, and availability,
but must not learn filenames, file metadata, search/index content, object bytes,
or revisions. The protocol encrypts its whole application payload, while Vault
encrypts stored content and metadata before handing it to the backend. A thief
who obtains the Mac pairing credential can impersonate that Mac pairing until it
is revoked; the credential therefore needs Keychain-backed storage in the final
Mac app UI rather than export or logging. The iPhone synchronizable Keychain
remains the only root-key recovery mechanism.

iOS and macOS do not guarantee continuous background execution. Sync is durable
and opportunistic: foreground work, system-granted background work, and retry on
the next reachable window. A sleeping/offline Mac or Tailscale client is a normal
unavailable state, not data loss.

The automated tests use deterministic in-process channels. They validate the
wire, storage, client adapter, replay behavior, permissions, quotas, ranges, and
revisions without a live network. They do **not** establish a real Tailscale,
DERP, MagicDNS, or Bonjour connection; those require a later two-device manual
validation matrix before shipping.

The iOS Stage 5 Settings flow accepts either a base64/JSON pairing capsule or
manually entered endpoint, server binding, nonce, expiry, and one-time code.
Endpoint and challenge sizes are validated before `prepareEnrollment` runs.
The server-binding fingerprint is shown in an explicit out-of-band confirmation
alert. Enrollment output is returned to the host for file/QR/paste exchange;
the UI deliberately has no unauthenticated network-enrollment fallback. A
successful credential is saved through the host's Keychain store, and Unpair
revokes the credential and removes the local record. Actual transport and
eviction remain injected backend seams.

The manual-entry path accepts only a canonical UUID pairing ID, a valid
Tailscale/Bonjour endpoint, 32-byte base64 server binding/nonce/one-time code,
and an ISO-8601 expiry still within the protocol's short offer lifetime.
Decoded JSON capsules are reconstructed through the same throwing validators so
Codable decoding cannot bypass those checks. Prepared enrollment is exposed
through copy, share, and document export; the host may additionally observe
the prepared value and rebuild its Mac runtime after credential persistence.
