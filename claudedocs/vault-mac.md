# Luna Vault Mac companion (v1 foundation)

The Mac storage option is a companion process owned and installed by the user.
Luna has no hosted relay, cloud bucket, or embedded Tailscale SDK. A user may
install and configure Tailscale separately, then give Vault a Tailscale CGNAT
address, Tailscale IPv6 address, or MagicDNS `*.ts.net` name. Tailscale chooses
the path: a direct peer path when available, or a DERP relay when it is not.
Luna cannot promise that a connection is direct. On the same LAN, the companion
can publish `_lunavault._tcp` and the iPhone-side browser can discover it; manual
`.local` entry remains a fallback.

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
