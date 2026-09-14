# Syncthing wire-protocol reference for a from-scratch client

Compiled 2026-09-15 from the official specs (docs "Written for v2.1.0", page
version `v2.1.0-24-g1f79d9e`) and the `main` branch of
`github.com/syncthing/syncthing` (latest tag at time of writing: `v2.1.5`).
Where the docs and the source disagree, the source wins and the disagreement is
called out with **DOCS vs SOURCE**. Every constant below was read from the
file cited in that section; nothing is from memory except the two general
encoding recaps in section J (protobuf, LZ4 block format), which cite their
public specifications.

Conventions: `BE` = big-endian. `varint` = protobuf base-128 varint. Byte
values are hex. "Syncthing" = the Go reference implementation.

---

## A. Block Exchange Protocol v1 (BEP)

Sources:
- Spec: https://docs.syncthing.net/specs/bep-v1.html
- Schema: https://raw.githubusercontent.com/syncthing/syncthing/main/proto/bep/bep.proto
- Framing/timers: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/protocol.go
- Hello: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/bep_hello.go
- TLS config: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/syncthing/syncthing.go , https://raw.githubusercontent.com/syncthing/syncthing/main/lib/tlsutil/tlsutil.go
- Peer validation: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/connections/service.go
- Dialers: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/connections/tcp_dial.go , `.../quic_dial.go`, `.../quic_misc.go`

### A.1 Transport and TLS

| Item | Value | Where |
| --- | --- | --- |
| TLS minimum | **TLS 1.3** (`tls.Config.MinVersion = VersionTLS13`, `tlsutil.SecureDefaultTLS13()`); TLS 1.2 is rejected. Spec text: "SHALL use TLS 1.3 or a higher revision". | `lib/syncthing/syncthing.go:263`, `lib/tlsutil/tlsutil.go` |
| Cipher suites | Not configurable in TLS 1.3 (Go negotiates AES-128-GCM-SHA256, AES-256-GCM-SHA384, CHACHA20-POLY1305-SHA256). The `cipherSuites` list in `tlsutil.go` is only applied by `SecureDefaultWithTLS12()`, which the GUI/API uses, not BEP. | `lib/tlsutil/tlsutil.go` |
| ALPN | `NextProtos = ["bep/1.0"]` (`bepProtocolName`). **Soft check**: if the peer did not negotiate `bep/1.0` Syncthing logs a warning ("Peer at did not negotiate bep/1.0") and continues. Send it anyway. | `lib/syncthing/syncthing.go:46,265`; `lib/connections/service.go:253-259` |
| Client cert | `ClientAuth = tls.RequestClientCert`: the server side asks for a certificate; the connection is dropped after the handshake if `len(PeerCertificates) != 1`. So you MUST send exactly one certificate (no chain). | `service.go:264-269` |
| Cert verification | `InsecureSkipVerify = true`. No CA, no expiry, no hostname check by TLS. Identity = SHA-256 of the peer's DER cert (`protocol.NewDeviceID(remoteCert.Raw)`), compared against the expected device ID. | `syncthing.go:268`, `service.go:271`, `service.go:1167-1197` |
| Session tickets | `SessionTicketsDisabled = true`. | `syncthing.go:267` |
| **CommonName check — ENFORCED** | After the Hello exchange, Syncthing takes `deviceCfg.CertName` (default empty → `tlsDefaultCommonName = "syncthing"`). If `remoteCert.Subject.CommonName == "syncthing"` it passes; otherwise it calls `remoteCert.VerifyHostname("syncthing")` (SAN DNSName match); if both fail it logs "Bad certificate from remote" and **closes the connection**. So your certificate MUST have `CN=syncthing` (or a SAN `DNS:syncthing`). | `service.go:404-421`, `syncthing.go:47` |
| Handshake timeout | 10 s (`tlsHandshakeTimeout`); TCP dial timeout 10 s; the Hello exchange has a 20 s deadline. | `service.go:80`, `tcp_dial.go:37`, `service.go:288` |
| Certificate Syncthing generates | Self-signed X.509 v3. Key: **Ed25519** (`x509.PureEd25519`) since v2.0.0; **ECDSA P-384 (SHA-256)** in v1.x (`v1.29.7 tlsutil.go:92`); RSA 3072 before v0.12.5. Subject `CN=syncthing, O=Syncthing, OU=Automatically Generated`, `DNSNames=["syncthing"]`, `SerialNumber` random uint64, `NotBefore` = today truncated to 24 h, `NotAfter` = +20*365 days (`deviceCertLifetimeDays = 20*365`), KeyUsage DigitalSignature|KeyEncipherment, ExtKeyUsage ServerAuth+ClientAuth, BasicConstraintsValid. Any key type Go's TLS 1.3 accepts works for a peer (RSA, ECDSA P-256/384/521, Ed25519) — Syncthing never inspects the key. | `tlsutil.go generateCertificate`, `syncthing.go:51` |
| Who is TLS client | On a direct TCP/QUIC connection: the dialer is the TLS client. On a relayed connection: decided by `SessionInvitation.ServerSocket` (see G). | `tcp_dial.go:54`, `relay_dial.go:47-52` |
| QUIC | Same `tls.Config` (so same ALPN `bep/1.0`), `quic.Config{MaxIdleTimeout: 30s, KeepAlivePeriod: 15s}`, one bidirectional stream carries BEP. Port default 22000/udp. | `quic_misc.go:24-27` |
| Address schemes | `tcp://`, `tcp4://`, `tcp6://`, `quic://`, `quic4://`, `quic6://`, `relay://`, `dynamic+http(s)://` (listener-side pool URL). Default listen: `tcp://0.0.0.0:22000`, `quic://0.0.0.0:22000`, `dynamic+https://relays.syncthing.net/endpoint`. | `lib/config/config.go:41-52` |

Connection-priority defaults (lower is better): TCP LAN 10, QUIC LAN 20, TCP WAN 30,
QUIC WAN 40, relay 50 (`lib/config/optionsconfiguration.go:78-82`). Reconnect
interval 20 s (min 5), relay reconnect 10 min.

### A.2 Pre-authentication Hello

Both sides send a Hello immediately after the TLS handshake, before anything
else, and both read the other's. Syncthing sends its Hello and then reads
(`ExchangeHello` = `writeHello` then `readHello`), so you may do the same
concurrently; do not wait for the peer's Hello before sending yours.

Wire layout (`bep_hello.go`):

```
offset  size  content
0       4     magic   0x2EA7D90B   (BE uint32)  = bytes 2E A7 D9 0B
4       2     length  BE uint16, MUST be <= 32767 ("hello message too big" otherwise)
6       len   protobuf Hello
```

DOCS vs SOURCE: the spec says the length is an int16 and lists only three
fields. The proto has five:

```proto
message Hello {
  string device_name    = 1;
  string client_name    = 2;
  string client_version = 3;
  int32  num_connections = 4;   // desired number of parallel connections; Syncthing sends its config value (default 1)
  int64  timestamp       = 5;   // time.Now().UnixNano() of the sender
}
```

Syncthing sends `client_name = "syncthing"`, `client_version = build.Version`
(e.g. `v2.1.5`), `timestamp = UnixNano`, `device_name` = its own configured name
(only if it already knows your device ID), `num_connections` = the configured
count for you. Old magics `0x9F79BC40` (v0.13) and first words `0x00010001`,
`0x00010000` are rejected as "too old"; any other magic is "unknown". A peer
whose device ID is unknown to Syncthing still gets the Hello exchange (so the
GUI can show "new device"), then the connection is closed.

`timestamp`: the two timestamps are summed to form a connection ID (`newConnectionID`);
0 is accepted from a peer.

### A.3 Post-authentication framing

Every message (`protocol.go writeMessage`/`readHeader`/`readMessageAfterHeader`):

```
offset  size   content
0       2      header length  BE uint16 (read as int16; negative → error)
2       H      Header protobuf
2+H     4      message length BE uint32 (read as int32; negative → error; > 500_000_000 → error)
6+H     L      message bytes (protobuf, or LZ4 container if Header.compression == LZ4)
```

```proto
message Header {
  MessageType        type        = 1;
  MessageCompression compression = 2;
}
enum MessageType {
  MESSAGE_TYPE_CLUSTER_CONFIG    = 0;
  MESSAGE_TYPE_INDEX             = 1;
  MESSAGE_TYPE_INDEX_UPDATE      = 2;
  MESSAGE_TYPE_REQUEST           = 3;
  MESSAGE_TYPE_RESPONSE          = 4;
  MESSAGE_TYPE_DOWNLOAD_PROGRESS = 5;
  MESSAGE_TYPE_PING              = 6;
  MESSAGE_TYPE_CLOSE             = 7;
}
enum MessageCompression {
  MESSAGE_COMPRESSION_NONE = 0;
  MESSAGE_COMPRESSION_LZ4  = 1;
}
```

Because proto3 omits zero-valued fields, a ClusterConfig with no compression has
an **empty** Header (header length `00 00`), a Ping header is `08 06` (length
`00 02`), a compressed Index header is `08 01 10 01`.

Unknown `MessageType` values are **skipped** by the reader for forward
compatibility (the length-prefixed body is consumed and ignored). Unknown
`compression` values close the connection.

`MaxMessageLen = 500 * 1000 * 1000` bytes applies to the on-wire message length
and to the LZ4 uncompressed length.

#### LZ4 compression

When `compression == LZ4`, the message body is:

```
0   4   uncompressed length, BE uint32 (must be <= 500_000_000)
4   ..  ONE raw LZ4 *block* (block format, NOT the LZ4 frame format; no frame
        magic, no block checksum, no content size). Produced by pierrec/lz4 v4
        CompressBlock, decoded by UncompressBlock.
```

Who compresses: the sender decides using **its own** per-device config
(`deviceCfg.Compression.ToProtocol()` passed to `NewConnection`), never the
value the receiver announced in ClusterConfig (`protocol.go:935-951`,
`service.go:429`):

- `METADATA` (default): compress every message except `Response` when the
  marshalled size is >= 128 bytes (`compressionThreshold`).
- `ALWAYS`: compress every message >= 128 bytes.
- `NEVER`: never.

Compression is skipped when it would not save at least `len/32` bytes.
**Consequence: you cannot opt out of receiving LZ4.** A default Syncthing peer
WILL send its Index/IndexUpdate/ClusterConfig (>=128 B) compressed. You must
implement an LZ4 block decoder (section J.2). You never have to *compress*: send
everything with `compression = NONE`. The `Device.compression` field you put in
ClusterConfig is informational for the other side's GUI/introducer copy.

### A.4 Message ordering and state machine

From `protocol.go dispatcherLoop`:

1. The first post-auth message in each direction MUST be `ClusterConfig`
   (`stateInitial` → `stateReady`). Any other type before it (except `Close`)
   is a protocol error and the connection is closed. Syncthing's writer loop
   likewise refuses to send anything before its own ClusterConfig is queued.
2. Additional `ClusterConfig` messages MAY be sent later (config change); the
   peer re-runs its folder handshake. `ClusterConfig.secondary = true` marks a
   secondary parallel connection: Syncthing ignores it except as "ready".
3. `Index` / `IndexUpdate` for a folder may be sent any time after
   ClusterConfig. Syncthing starts sending its index for a folder as soon as it
   has processed YOUR ClusterConfig and found the folder shared with you
   (`indexHandler` registered by `AddIndexInfo`); it does not wait for your Index.
4. `Request` may be sent any time after ClusterConfig; responses are matched by
   `id` only, may arrive out of order, and MUST have unique ids among
   outstanding requests. Syncthing processes each incoming Request in its own
   goroutine.
5. `Close` MAY be sent before tearing down; nothing may follow it. Receiving a
   Close ends the connection with error `closed by remote: <reason>`.
6. `Ping`: sender side — Syncthing ticks every 45 s (`PingSendInterval/2`) and
   sends a Ping if nothing was **written** in the last 45 s, giving an effective
   interval of 45–90 s. Receiver side — if nothing (any message) was **read**
   for `ReceiveTimeout = 300 s` the connection is closed with `read timeout`
   (checked every 150 s). So: send something at least every ~90 s; tolerate
   silence up to 300 s. `CloseTimeout = 10 s` is how long Syncthing waits for
   the Close message to be written.

Per-message validation Syncthing applies to what YOU send (a failure closes the
connection with "protocol error"):

- File names (`checkFilename`, Index/IndexUpdate/Request): `path.Clean(name) == name`
  (so no `./`, `//`, trailing `/`), not `""`, `"."`, `".."`, no leading `/`, no
  leading `../`. Names are UTF-8 **NFC**, `/` separated, folder-relative
  (`wireformat.go` normalises outgoing names with `norm.NFC` + `filepath.ToSlash`).
- FileInfo consistency (`checkFileInfoConsistency`): `deleted` ⇒ no blocks;
  non-FILE type ⇒ no blocks; DIRECTORY ⇒ `size == 0` (128 is tolerated for
  legacy); SYMLINK ⇒ `size == 0`; a FILE that is not deleted and not invalid
  ⇒ **at least one block** (an empty file carries one block of size 0 with the
  SHA-256 of nothing, see B).
- Request: `size >= 0`, `size <= MaxRequestSize = 2 * 16 MiB = 33_554_432`,
  and **`hash` MUST be non-empty** ("request missing block hash", enforced
  since v1.28.1).

### A.5 Message schemas (current `main`, `proto/bep/bep.proto`)

Type column is the proto scalar; wire type in brackets (V = varint, L =
length-delimited).

#### ClusterConfig

```proto
message ClusterConfig {
  repeated Folder folders = 1;   [L]
  bool secondary          = 2;   [V]  // true only on a 2nd+ parallel connection
}

message Folder {
  string id                    = 1;  [L]
  string label                 = 2;  [L]
  FolderType type              = 3;  [V]
  FolderStopReason stop_reason = 7;  [V]
  reserved 4 to 6;                       // v1: ignore_permissions=4, ignore_delete=5, disable_temp_indexes=6
  repeated Device devices      = 16; [L]
}

message Device {
  bytes  id                         = 1;  [L] 32 raw bytes
  string name                       = 2;  [L]
  repeated string addresses         = 3;  [L] e.g. "tcp://1.2.3.4:22000", "dynamic"
  Compression compression           = 4;  [V]
  string cert_name                  = 5;  [L] usually ""
  int64  max_sequence               = 6;  [V]
  bool   introducer                 = 7;  [V]
  uint64 index_id                   = 8;  [V]
  bool   skip_introduction_removals = 9;  [V]
  bytes  encryption_password_token  = 10; [L] empty unless untrusted-device encryption
}

enum Compression  { COMPRESSION_METADATA = 0; COMPRESSION_NEVER = 1; COMPRESSION_ALWAYS = 2; }
enum FolderType   { FOLDER_TYPE_SEND_RECEIVE = 0; FOLDER_TYPE_SEND_ONLY = 1;
                    FOLDER_TYPE_RECEIVE_ONLY = 2; FOLDER_TYPE_RECEIVE_ENCRYPTED = 3; }
enum FolderStopReason { FOLDER_STOP_REASON_RUNNING = 0; FOLDER_STOP_REASON_PAUSED = 1; }
```

**v1 → v2 change (commit 95187bcc64, 2025-06-29, shipped in v2.0.0).** The v1
`Folder` was `bool read_only = 3; bool ignore_permissions = 4; bool ignore_delete = 5;
bool disable_temp_indexes = 6; bool paused = 7;` (verified in tag v1.29.7). The
new enums were chosen so the wire bytes are identical: `read_only=true` ⇔
`type = SEND_ONLY (1)`; `paused=true` ⇔ `stop_reason = PAUSED (1)`. Fields 4–6
are now reserved and ignored. A v2 peer reading a v1 client sees the same
values. DOCS vs SOURCE: the docs already show the v2 form.

Semantics Syncthing applies when it receives your ClusterConfig (`lib/model/model.go
ClusterConfig`, `ccHandleFolders`):

- For every folder you list, the `devices` list MUST contain an entry for
  **you** (the sender) and one for **the receiver**; otherwise the connection
  is closed with `errMissingRemoteInClusterConfig` /
  `errMissingLocalInClusterConfig`. Other devices are optional (used for
  introductions only).
- In *your own* Device entry: `index_id` and `max_sequence` describe YOUR
  index (random 64-bit non-zero id created with your database; highest sequence
  you have). In *the receiver's* Device entry: `index_id` and `max_sequence`
  are what you have STORED about THEIR index — this is how delta indexes resume
  (see A.6).
- Folder not known / not shared with you on their side → they record a
  "pending folder" offer (GUI shows "X wants to share folder"), log a warning,
  and ignore it. Nothing is closed.
- `stop_reason != RUNNING` → they treat you as paused for that folder and send
  no index.
- `type`/`compression`/`introducer`/`name`/`addresses` are informational
  (folder `type` is *not* read by the model; the per-device compression used
  for sending is the receiver's own config).
- Encryption consistency (`ccCheckEncryption`): if neither side has an
  `encryption_password_token` and the device is not marked untrusted, nothing
  happens. Do not set the token.
- `secondary = true` → the whole message is ignored ("merely indicates the
  connection is ready").

#### Index / IndexUpdate

```proto
message Index {
  string folder            = 1;  [L]
  repeated FileInfo files  = 2;  [L]
  int64 last_sequence      = 3;  [V]  // highest sequence in this batch (v1.29+; 0 = not stated)
}
message IndexUpdate {
  string folder            = 1;  [L]
  repeated FileInfo files  = 2;  [L]
  int64 last_sequence      = 3;  [V]
  int64 prev_sequence      = 4;  [V]  // highest sequence of the previous batch
}
```

DOCS vs SOURCE: the docs omit `last_sequence`/`prev_sequence`. Syncthing
only uses them for anomaly logging (`logSequenceAnomaly` → events, never a
disconnect). Setting both to 0 is accepted ("if prevSequence > 0 && …").

`Index` **replaces** everything the receiver stored about your folder
(`DropAllFiles` then insert). `IndexUpdate` merges. Syncthing sends its first
batch as `Index` only when `startSequence == 0` (full transfer), otherwise
every batch is `IndexUpdate`; each batch is at most `MaxBatchSizeFiles`
FileInfos. Ordering: files MUST be in increasing `sequence`.

#### FileInfo

```proto
message FileInfo {
  string  name             = 1;    [L]  UTF-8 NFC, '/'-separated, folder relative
  FileInfoType type        = 2;    [V]
  int64   size             = 3;    [V]  0 for dirs/symlinks/deleted
  uint32  permissions      = 4;    [V]  Unix mode bits (0o777 mask compared)
  int64   modified_s       = 5;    [V]  Unix seconds
  bool    deleted          = 6;    [V]
  bool    invalid          = 7;    [V]  cannot serve / do not sync this entry
  bool    no_permissions   = 8;    [V]  permissions unknown; spec: set permissions to 0666
  Vector  version          = 9;    [L]
  int64   sequence         = 10;   [V]
  int32   modified_ns      = 11;   [V]
  uint64  modified_by      = 12;   [V]  short device ID of last modifier
  int32   block_size       = 13;   [V]  0 ⇒ 131072
  PlatformData platform    = 14;   [L]  ownership / xattrs; omit
  repeated BlockInfo blocks = 16;  [L]
  bytes   symlink_target   = 17;   [L]  DOCS say string; proto is bytes (same wire type 2)
  bytes   blocks_hash      = 18;   [L]  SHA-256 over the concatenated block hashes (see B)
  bytes   encrypted        = 19;   [L]  untrusted-device encryption only; omit
  bytes   previous_blocks_hash = 20; [L] v2.0.16+/2.1: blocks_hash of the version this one was derived from
  uint32  local_flags      = 1000; [V]  NEVER sent (Syncthing zeroes it); ignore if received
  bytes   version_hash     = 1001; [L]  never sent; DB only
  reserved 1002;                        // v1: int64 inode_change_ns, removed 2026-03 (commit b39c56f82d)
  int32   encryption_trailer_size = 1003; [V] never sent
}

enum FileInfoType {
  FILE_INFO_TYPE_FILE              = 0;
  FILE_INFO_TYPE_DIRECTORY         = 1;
  FILE_INFO_TYPE_SYMLINK_FILE      = 2 [deprecated];   // treat as SYMLINK
  FILE_INFO_TYPE_SYMLINK_DIRECTORY = 3 [deprecated];   // treat as SYMLINK
  FILE_INFO_TYPE_SYMLINK           = 4;
}

message BlockInfo {
  int64 offset = 1;  [V]
  int32 size   = 2;  [V]
  bytes hash   = 3;  [L]  32 bytes SHA-256
  reserved 4;             // v1: uint32 weak_hash, removed 2025-03 (commit b1c8f88a44), v2.0.0
}

message Vector  { repeated Counter counters = 1; [L] }
message Counter { uint64 id = 1; [V]  uint64 value = 2; [V] }

message PlatformData { UnixData unix = 1; WindowsData windows = 2; XattrData linux = 3;
                       XattrData darwin = 4; XattrData freebsd = 5; XattrData netbsd = 6; }
message UnixData    { string owner_name = 1; string group_name = 2; int32 uid = 3; int32 gid = 4; }
message WindowsData { string owner_name = 1; bool owner_is_group = 2; }
message XattrData   { repeated Xattr xattrs = 1; }
message Xattr       { string name = 1; bytes value = 2; }
```

Receiving side note: when Syncthing receives `invalid = true` it stores the
entry with local flag `FlagLocalRemoteInvalid` and never requests it. When it
sends, `invalid` is `true` if any of its local flags Unsupported / Ignored /
MustRescan / ReceiveOnly / RemoteInvalid is set.

`prepareFileInfoForIndex`: outgoing entries changed locally on a receive-only
folder are sent with an **empty** `version` so they never win globally.

#### Request / Response

```proto
message Request {
  int32  id             = 1;  [V]
  string folder         = 2;  [L]
  string name           = 3;  [L]
  int64  offset         = 4;  [V]
  int32  size           = 5;  [V]  <= 33_554_432
  bytes  hash           = 6;  [L]  REQUIRED, 32 bytes (connection closed if empty)
  bool   from_temporary = 7;  [V]  read from the peer's ".syncthing.<name>.tmp" in-progress file
  reserved 8;                       // v1: uint32 weak_hash
  int32  block_no       = 9;  [V]  = offset / block_size
}

message Response {
  int32     id   = 1;  [V]
  bytes     data = 2;  [L]
  ErrorCode code = 3;  [V]
}
enum ErrorCode {
  ERROR_CODE_NO_ERROR     = 0;
  ERROR_CODE_GENERIC      = 1;
  ERROR_CODE_NO_SUCH_FILE = 2;
  ERROR_CODE_INVALID_FILE = 3;
}
```

Serving side (`model.go Request`) — what Syncthing returns and therefore what a
compatible server should return:

| Situation | code |
| --- | --- |
| `size < 0` or `offset < 0` | INVALID_FILE |
| folder unknown / not shared with requester / paused; name not canonical; read I/O error | GENERIC |
| name is an internal path (`.stfolder`, `.stignore`, `.stversions`) or matches ignore patterns | INVALID_FILE |
| path traverses a symlink; file missing or not a regular file; read hits ENOENT; **data read does not hash to `hash`** | NO_SUCH_FILE |
| success | NO_ERROR, `data` = exactly the bytes (short at EOF is allowed; hash decides) |

Syncthing also verifies `sha256(data) == request.hash` before answering and
returns NO_SUCH_FILE on mismatch (then rescans the file). The receiver
(`folder_sendrecv.go pullBlock`) treats every non-zero code and every hash
mismatch identically: log at debug, drop this device from the candidate list
for this block, try the next device that advertised the block; when no
candidates remain the file pull fails and is retried on the next pull cycle.
No code causes a disconnect.

#### DownloadProgress (optional; you may never send it)

```proto
message DownloadProgress {
  string folder                                = 1; [L]
  repeated FileDownloadProgressUpdate updates  = 2; [L]
}
message FileDownloadProgressUpdate {
  FileDownloadProgressUpdateType update_type = 1; [V]
  string name                                = 2; [L]
  Vector version                             = 3; [L]
  repeated int32 block_indexes               = 4 [packed = false];  // one tag per element!
  int32 block_size                           = 5; [V]  (not in docs)
}
enum FileDownloadProgressUpdateType { ..._APPEND = 0; ..._FORGET = 1; }
```

Sent every 5 s by default when partial downloads exist. Ignore incoming ones
unless you want to fetch from a peer's temp files (`from_temporary`).

#### Ping / Close

```proto
message Ping {}                       // zero-length body: frame is 00 02 08 06 00 00 00 00
message Close { string reason = 1; }  // [L]
```

### A.6 Delta index resume (index_id / max_sequence)

From `lib/model/indexhandler.go newIndexHandler` and the spec's "Delta Index Exchange":

- Each device keeps, per folder, an `IndexID` (random uint64, `NewIndexID()`,
  regenerated whenever its sequence counter is reset) and a monotonically
  increasing `sequence` (+1 per local database change; assigned to the
  FileInfo).
- In your ClusterConfig, in the Device entry **about the peer**, put the
  peer's `index_id` and the highest `sequence` you have stored from them
  (`max_sequence`). The peer then:
  - if `index_id == its current id` and `max_sequence <= its sequence` → sends
    only `IndexUpdate`s for `sequence > max_sequence` (may be nothing);
  - if `index_id == its id` but `max_sequence > its sequence` → "out of sync
    with reality", sends a full `Index`;
  - if `index_id == 0` → full `Index`;
  - otherwise (stale id) → full `Index`.
- In the Device entry **about yourself**, put your own `index_id` and
  `max_sequence`. The peer: if `index_id == 0` → drops everything stored about
  you and expects a full Index; if it differs from what it stored → drops and
  stores the new id; if equal → keeps its copy and merges your IndexUpdates.
- "Devices not intending to participate in delta index exchange MUST send a
  zero index ID." A device announcing a non-zero index ID MUST send index data
  ordered by increasing sequence.

Simplest correct client: send `index_id = 0`, `max_sequence = 0` for BOTH
entries, always receive the peer's full Index on every connection, always send
your own full `Index` (or an empty one).

### A.7 Sharing modes

Send Only / Receive Only / Receive Encrypted are *local policies* enforced by
each device on itself. On the wire the only visible effects are: the
`Folder.type` enum (informational), a receive-only device sending
locally-changed items with `invalid = true` and an empty version, and a
receive-encrypted device carrying `encryption_password_token`. Nothing else
changes.

---

## B. Blocks and hashes

Sources:
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/protocol.go (constants)
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/bep_fileinfo.go (`BlockSize`, `BlocksHash`, `sha256OfEmptyBlock`)
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/scanner/blocks.go
- https://docs.syncthing.net/specs/bep-v1.html#selection-of-block-size

| Constant | Value |
| --- | --- |
| `MinBlockSize` | 128 KiB = 131 072 |
| `MaxBlockSize` | 16 MiB = 16 777 216 |
| valid block sizes | 128 KiB, 256 KiB, 512 KiB, 1, 2, 4, 8, 16 MiB (powers of two only; anything else is invalid) |
| `DesiredPerFileBlocks` | 2000 |
| `MaxRequestSize` | 2 × MaxBlockSize = 33 554 432 |

Block size selection (`protocol.BlockSize(fileSize)`): the smallest valid size
`b` such that `fileSize < 2000 * b`, else 16 MiB. Table:

| file size | block size |
| --- | --- |
| 0 – 250 MiB (exclusive) | 128 KiB |
| 250 – 500 MiB | 256 KiB |
| 500 MiB – 1 GiB | 512 KiB |
| 1 – 2 GiB | 1 MiB |
| 2 – 4 GiB | 2 MiB |
| 4 – 8 GiB | 4 MiB |
| 8 – 16 GiB | 8 MiB |
| ≥ 16 GiB | 16 MiB |

Boundaries are `fileSize < 2000*b`, so a 262 144 000-byte file (exactly 250 MiB)
gets 256 KiB. A receiver MUST accept any valid block size regardless of file
size. `FileInfo.block_size = 0` means 128 KiB.

Block list (`scanner.Blocks`): consecutive `block_size` slices, last one
shorter; each `BlockInfo{offset, size, hash = SHA-256(slice)}`. An **empty
file** has exactly one block `{offset 0, size 0, hash = SHA-256("") =
e3b0c442 98fc1c14 9afbf4c8 996fb924 27ae41e4 649b934c a495991b 7852b855}`.

`blocks_hash` (`protocol.BlocksHash`): `SHA-256(hash_0 ‖ hash_1 ‖ … ‖ hash_n)` —
the raw 32-byte hashes concatenated in order, nothing else. Syncthing uses it
to short-cut block-list equality and for conflict detection
(`previous_blocks_hash`). Optional but cheap; send it.

Empty (all-zero) blocks: Syncthing recognises the SHA-256 of a full block of
zeroes for each block size (`sha256OfEmptyBlock`, e.g. 128 KiB →
`fa43239bcee7b97ca62f007cc68487560a39e19f74f3dde7486db3f98df8e471`) and does
not request them (writes zeroes / leaves a sparse hole).

**Weak hash: removed.** `BlockInfo.weak_hash` (field 4) and `Request.weak_hash`
(field 8) were Adler-32-style rolling hashes; both were deleted in commit
b1c8f88a44 (2025-03-29, released in v2.0.0) and the fields are `reserved`. Do
not send them. A v1.x peer that receives no weak hash treats it as 0 =
"unknown" and falls back to SHA-256 only, so omission was always legal.

---

## C. Version vectors, conflicts, deletes

Sources:
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/vector.go
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/deviceid.go (`Short()`)
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/bep_fileinfo.go (`InConflictWith`, `WinsConflict`, `SetDeleted`)
- https://docs.syncthing.net/specs/bep-v1.html (FileInfo fields)

- `Counter.id` = **short device ID** = the first 8 bytes of the 32-byte device
  ID read as a **big-endian uint64** (`binary.BigEndian.Uint64(n[:8])`,
  `DeviceID.Short()`). Its 7-character display form is the first 7 chars of
  the base32 encoding of those 8 bytes (e.g. `MFZWI3D`).
- Counters in a Vector are kept **sorted by id ascending**; `Update` inserts in
  order and `Merge`/`Compare` walk both lists in id order. Send them sorted.
- Incrementing on local change (`Vector.Update(id)`): the device's own
  counter becomes `max(old + 1, now_unix_seconds)`; a missing counter is
  created with `max(1, now_unix_seconds)`. So counter values are Unix
  timestamps when the clock is sane; this makes counters comparable across a
  database reset. Any strictly increasing value works for peers.
- Ordering (`Compare`): walk the union of ids; a missing counter is 0. If every
  counter of A ≥ B's → A ≥ B; if some greater and some smaller →
  **concurrent** (conflict). `Equal` when identical.
- Global version: the entry with the greater vector wins. Concurrent vectors
  are a conflict; Syncthing resolves it by `WinsConflict`: an invalid entry
  loses; else the later modification time (`modified_s`,`modified_ns`) wins;
  on a tie, the vector whose comparison yields `ConcurrentGreater` wins
  (deterministic by id/value). The losing file is renamed
  `<name>.sync-conflict-<YYYYMMDD>-<HHMMSS>-<SHORTID>.<ext>`. `InConflictWith`
  (v2.1) additionally treats a concurrent version as *not* a conflict when
  `previous_blocks_hash` of the newcomer equals the local `blocks_hash`.
- Merging when you adopt a remote version: store its vector as-is. When you
  then modify the file, `Update(myID)` on that vector.
- Delete (`SetDeleted`): `deleted = true`, `size = 0`, `blocks = []`,
  `blocks_hash = empty`, `modified_by = myShortID`, `version =
  version.Update(myShortID)`, `modified_s = now`. Deleted entries stay in the
  index forever (a tombstone) so peers can order them.
- `modified_by` = short ID of the device that made the last change (add,
  modify or delete). Set it to your short ID on every entry you originate.
- `sequence` is per-device and unrelated to version; increment it on every
  index write you make.

---

## D. Device IDs

Sources:
- https://docs.syncthing.net/dev/device-ids.html
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/deviceid.go
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/protocol/luhn.go

Algorithm (`DeviceID.String()`):

1. `raw = SHA-256(certificate DER bytes)` — the full `Certificate` structure as
   sent in TLS (`tls.ConnectionState.PeerCertificates[0].Raw`), 32 bytes.
2. `s = base32(raw)` with the RFC 4648 alphabet `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`;
   56 chars with `====` padding; strip the `=` → **52 chars**.
3. Split into **4 groups of 13**. For each group compute a check char with
   `luhn32` (below) and append it → 4 × 14 = **56 chars**.
4. Insert `-` every 7 chars → **8 groups of 7**, 63 chars total, e.g.
   `MFZWI3D-BONSGYC-YLTMRWG-C43ENR5-QXGZDMM-FZWI3DP-BONSGYY-LTMRWAD`.
   (Not "7 groups of 7 + 1 of 8": each 14-char luhnified group is displayed as
   two 7-char dash groups; the check char is the last char of every even
   group.)

`luhn32(s)` — NOT the standard Luhn (see forum thread cited in source):

```
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"   // codepoint = index, 0..31
factor = 1; sum = 0; n = 32
for each char c in s (left to right):
    addend = factor * codepoint(c)
    factor = (factor == 2) ? 1 : 2          // alternates 1,2,1,2,... starting with 1
    addend = addend / n + addend % n         // integer division
    sum += addend
remainder = sum % n
check = (n - remainder) % n
return alphabet[check]
```

Parsing (`UnmarshalText`): strip `=`, upper-case, `untypeoify` (`0→O`, `1→I`,
`8→B`), remove `-` and spaces; length 56 → verify the four check chars and
drop them; length 52 → old style without check chars; then base32-decode with
`====` appended. Both forms are accepted everywhere a device ID string is read
(config, discovery `?device=`, relay `?id=`).

Short ID: first 8 bytes of `raw`, BE uint64 (section C). Reserved values:
`LocalDeviceID` = 32 × `0xFF`, `GlobalDeviceID` = 32 × `0xF8`, `EmptyDeviceID` =
all zero (never valid on the wire).

---

## E. Global discovery v3

Sources:
- https://docs.syncthing.net/specs/globaldisco-v3.html
- Client: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/discover/global.go
- Server: https://raw.githubusercontent.com/syncthing/syncthing/main/cmd/stdiscosrv/apisrv.go , `.../main.go`
- Defaults: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/config/config.go , `.../lib/config/optionsconfiguration.go`
- Address sources: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/connections/service.go (`ExternalAddresses`, `AllAddresses`), `.../tcp_listen.go` (`WANAddresses`, `LANAddresses`)

### E.1 Default servers (config.go:54-68)

```
https://discovery-lookup.syncthing.net/v2/?noannounce        (lookup only, both v4 and v6 lists)
https://discovery-announce-v4.syncthing.net/v2/?nolookup     (announce over IPv4)
https://discovery-announce-v6.syncthing.net/v2/?nolookup     (announce over IPv6)
```

The literal `default` in a Syncthing config expands to those three. Older
docs/configs use `https://discovery.syncthing.net/v2/`; `/v2/` is the
conventional path ("Standard discovery currently requires the path to be /v2/").
The `?noannounce`, `?nolookup`, `?insecure`, `?id=<DEVICE-ID>` query
parameters are **client-side options**, stripped before the request is sent
(`parseOptions`). `http://` is allowed only with `insecure` **and** `noannounce`.

### E.2 Server certificate

The public servers do **not** use a publicly trusted certificate. Syncthing
sets `InsecureSkipVerify = true` when an `id` is given (or `insecure`), and
instead pins: after each response it checks `sha256(resp.TLS.PeerCertificates[0].Raw)`
equals the device ID from `?id=` (`idCheckingHTTPClient.check`). For the
default URLs no `?id=` is present, so Syncthing verifies them with the normal
system CA store (they currently do carry a valid public cert; a private
`stdiscosrv` prints its device ID on start-up and you pin that). Client TLS
min version 1.2; HTTP/2 enabled; request timeout 30 s.

### E.3 Announce

`POST <server>` (e.g. `https://discovery-announce-v4.syncthing.net/v2/`),
`Content-Type: application/json`, **client TLS certificate required** (your
device certificate; the server derives your device ID from it — no ID in the
body), body:

```json
{"addresses":["tcp://0.0.0.0:22000","quic://0.0.0.0:22000","tcp://192.168.1.10:22000","relay://82.67.219.252:22067/?id=R6FRYWN-…"]}
```

Server (`apisrv.go handlePOST`, `fixupAddresses`):
- 403 Forbidden if no client certificate; 400 if JSON bad or no usable address.
- Each address is URL-parsed; loopback and multicast hosts dropped; an empty
  or unspecified host (`tcp://:22000`, `tcp://0.0.0.0:22000`, `tcp://[::]:22000`)
  is replaced by the request's **source IP** (`X-Forwarded-For` honoured
  behind a proxy) — skipped if the scheme ends in `4` and the source is IPv6
  or vice versa; port `0` is replaced by the request's source port (TCP hole
  punching hint). Everything else is kept **verbatim**, including RFC 1918
  addresses.
- Success: `204 No Content` with header `Reannounce-After: <seconds>` = 2400 +
  rand(0..1800). Records expire after 2 h (`addressExpiryTime`).
- Errors carry `Retry-After: <seconds>` = 1800 + rand(0..900). 429 may be
  returned on abuse.
- Client behaviour (`global.go`): first announce ~5 s after start, then per
  `Reannounce-After` (default 30 min), retry errors after `Retry-After` or 5
  min; debounce address changes by 2 s; nothing to announce → no request.

**Private LAN addresses ARE announced by default.** `ExternalAddresses()`
returns `AllAddresses()` (LAN + WAN of every listener) when
`Options.AnnounceLANAddresses` is true, and that option defaults to **true**
(`optionsconfiguration.go:66`). WAN addresses of a TCP listener are the
listen URI itself (`tcp://0.0.0.0:22000` → rewritten to your public IP by the
server), `tcp://0.0.0.0:0` when SO_REUSEPORT is available, and any NAT-PMP/UPnP
mapped `tcp://<extIP>:<extPort>`; LAN addresses are `tcp://<each interface
IP>:22000`. Relay listeners contribute their `relay://…?id=…` URL (other
relay query parameters are stripped: `sanitizeRelayAddresses` allow-list =
`id`). So a lookup from the same LAN normally returns the direct private
address too. DOCS vs SOURCE: the device-IDs page still says "the internal
address is not announced to the global server"; that text predates the
`announceLANAddresses` option.

### E.4 Lookup

`GET <server>?device=<CANONICAL-DEVICE-ID>` (dashes + check digits,
URL-encoded; `q.Set("device", device.String())`). No client cert needed (the
lookup client sends none).

- `200 OK`, `Content-Type: application/json`, optional gzip when requested:
  `{"seen":"2026-09-15T10:11:12Z","addresses":["tcp://203.0.113.5:22000","tcp://192.168.1.10:22000","relay://…"]}`.
  `seen` = last announce time truncated to seconds (RFC 3339, Go `time.Time`
  JSON). Addresses never contain unspecified hosts.
- `400` bad/missing `device` (with `Retry-After`).
- `404 Not Found` with `Retry-After: <s>` — device unknown or all its
  addresses expired. The seconds value is adaptive (60–3600 for never-seen
  devices; a separate tracker for seen-but-idle ones). Syncthing caches the
  negative result for that long.
- `429` on rate limiting (also carries `Retry-After`).
- `500` internal (`Retry-After`).

### E.5 Address URL forms you will see

- `tcp://host:port`, `tcp4://…`, `tcp6://…`, `quic://…`, `quic4://…`, `quic6://…`
  (IPv6 host in brackets). Port omitted ⇒ 22000.
- `relay://host:port/?id=<RELAY-DEVICE-ID>&pingInterval=1m0s&networkTimeout=2m0s[&sessionLimitBps=N][&globalLimitBps=N][&statusAddr=:22070][&providedBy=text][&token=…]`
  as published by `strelaysrv` (`cmd/strelaysrv/main.go:245-268`). In
  discovery/ClusterConfig only `id` survives. Only `id` (verification) and
  `token` (private relays) are read by the client.
- `dynamic+https://relays.syncthing.net/endpoint` — a *listener* config value,
  never an address of a device.
- Special string `dynamic` in a device's configured address list means "use
  discovery".

---

## F. Local discovery v4

Sources:
- https://docs.syncthing.net/specs/localdisco-v4.html
- https://raw.githubusercontent.com/syncthing/syncthing/main/proto/discoproto/local.proto
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/discover/local.go
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/beacon/broadcast.go , `.../multicast.go`
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/config/optionsconfiguration.go

| Item | Value |
| --- | --- |
| Transport | UDP, destination port **21027** (`LocalAnnPort`) |
| IPv4 | broadcast to each interface's subnet broadcast address (and/or `255.255.255.255`), from a socket bound to `0.0.0.0:21027` (`ListenUDP udp4 :21027`) |
| IPv6 | multicast to **`[ff12::8384]:21027`** (`LocalAnnMCAddr`), joined on every running multicast-capable interface (cellular skipped) |
| Interval | every **30 s** (`BroadcastInterval`); spec allows 30–60 s; an immediate extra send when a new device/instance is heard |
| Cache lifetime | 3 × 30 s = 90 s (`CacheLifeTime`) |
| Magic | `0x2EA7D90B` BE (same as BEP Hello). Old v13 magic `0x7D79BC40` is rejected. |

Packet: `2E A7 D9 0B` followed immediately by the protobuf; no length field
(datagram length bounds it).

```proto
message Announce {
  bytes           id          = 1;  [L] 32-byte device ID
  repeated string addresses   = 2;  [L]
  int64           instance_id = 3;  [V] random per process start
}
```

Receiver rules (`local.go registerDevice`): own ID ignored; each address is
URL-parsed and `net.ResolveTCPAddr`'d — unspecified/empty host replaced by the
datagram's **source IP** (respecting `tcp4`/`tcp6` scheme suffixes), others
kept verbatim; a changed `instance_id` ⇒ device restarted ⇒ treated as new.
Sender filter (`filterUndialableLocal`): drops loopback/multicast/port-0
addresses, keeps global-unicast, link-local-unicast and unspecified ones;
relay URLs are reduced to `?id=` only. So announcing
`["tcp://0.0.0.0:22000"]` is enough for LAN peers to find you. Local discovery
is unauthenticated (spoofable) by design.

---

## G. Relay protocol v1

Sources:
- https://docs.syncthing.net/specs/relay-v1.html
- Wire types: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/relay/protocol/packets.go , `.../packets_xdr.go`, `.../protocol.go`
- XDR primitives: https://raw.githubusercontent.com/calmh/xdr/master/marshaller.go , `.../unmarshal.go`, `.../common.go`
- Client: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/relay/client/static.go , `.../methods.go`, `.../dynamic.go`, `.../client.go`
- BEP over relay: https://raw.githubusercontent.com/syncthing/syncthing/main/lib/connections/relay_dial.go , `.../relay_listen.go`
- Server: https://raw.githubusercontent.com/syncthing/syncthing/main/cmd/strelaysrv/main.go , `.../listener.go`, `.../session.go`
- Pool: https://relays.syncthing.net/endpoint (fetched 2026-09-15)

### G.1 Relay pool

`GET https://relays.syncthing.net/endpoint` → `{"relays":[{"url":"relay://82.67.219.252:22067/?id=R6FRYWN-SSKTBAY-4OLFELW-AXKT4ZT-G7HQ3NE-CP3DTVR-Z5EBOET-MAHPCAE"}, …]}`
(100 entries returned today; each object carries only `url` — the older
`stats` sub-object is no longer served). Syncthing's dynamic client parses
`Relays[].URL`, measures TCP-connect latency to each, buckets by 50 ms,
shuffles within buckets and joins the first that works. The relay's own device
ID is the `id` parameter and is the ONLY thing that authenticates the relay.

### G.2 Protocol-mode connection (TLS)

- TCP to `host:port` from the URL (default port 22067), then TLS **client**
  with: ALPN `NextProtos = ["bep-relay"]` (`protocol.ProtocolName`),
  `MinVersion = TLS 1.2`, your device certificate presented
  (`Certificates: certs`, so the relay learns your ID), `InsecureSkipVerify`,
  session tickets disabled, `ServerName` = host (SNI), cipher suites list
  `ECDHE_RSA/ECDSA_WITH_AES_128_GCM_SHA256, …AES_128_CBC_SHA, …AES_256_CBC_SHA`
  (ignored under 1.3). The relay side: TLS 1.3 accepted? The server uses the
  same list with `MinVersion` 1.2 in `strelaysrv/main.go:175`; TLS 1.3 works.
- After the handshake the client REQUIRES `NegotiatedProtocol == "bep-relay"`
  ("protocol negotiation error" otherwise) and, when `?id=` is present,
  REQUIRES exactly one peer certificate whose SHA-256 equals that device ID.
- The relay distinguishes protocol mode from session mode by the first byte:
  `0x16` (TLS handshake) ⇒ protocol mode; anything else ⇒ session mode.

### G.3 Message framing (XDR, all big-endian, 4-byte aligned)

```
header (12 bytes):
  uint32 magic         = 0x9E79BC40
  int32  messageType
  int32  messageLength   (payload bytes; relay rejects < 0 or > 1024)
payload: XDR-encoded struct, see below
```

Message types (`packets.go`, iota from 0 — confirmed):

| type | name | XDR payload |
| --- | --- | --- |
| 0 | Ping | (empty, length 0) |
| 1 | Pong | (empty) |
| 2 | JoinRelayRequest | `string Token<>` — **added in v1.x**; a private relay compares it to its `-token`. Public relays: send `Token = ""` → payload `00 00 00 00` (length 4). The relay also accepts a zero-length payload (pre-token form). |
| 3 | JoinSessionRequest | `opaque Key<32>` |
| 4 | Response | `int32 Code; string Message<>` |
| 5 | ConnectRequest | `opaque ID<32>` (32-byte device ID of the peer you want) |
| 6 | SessionInvitation | `opaque From<32>; opaque Key<32>; opaque Address<32>; uint16 Port; bool ServerSocket` |
| 7 | RelayFull | (empty) |

XDR encoding rules used by `calmh/xdr`:
- `uint32`/`int32`: 4 bytes BE.
- `uint16`, `uint8`, `bool`: **also a full 4-byte word**, value in the low
  bytes: `MarshalUint16(v)` = `MarshalUint32(uint32(v))` (bytes `00 00 hi lo`);
  `bool` = `00 00 00 01` / `00 00 00 00`. Decoding reads `Data[3]` (u8) or
  `Data[2..3]` (u16) and skips 4.
- `opaque<>` / `string<>`: `uint32 length`, then the bytes, then `Padding(len)
  = (4 - len%4) % 4` zero bytes. `<32>` is a maximum (decoder errors above it).
- Empty structs marshal to zero bytes.

Example SessionInvitation payload size: 4+32 + 4+32 + 4+len(addr)+pad + 4 + 4.
`Address` is a raw IP (4 or 16 bytes) — `net.IP(msg.Address)`; if empty or
unspecified (`0.0.0.0`/`::`) the client substitutes the IP it used to reach the
relay (`osutil.IPFromAddr(conn.RemoteAddr())`). `strelaysrv` fills `Address`
with the IP of its `-ext-address` (defaults to the listen address, usually
unspecified → empty) and `Port` with its port.

Response codes (`protocol.go`): 0 success, 1 not found, 2 already connected,
3 wrong token, 100 unexpected message (docs also list 99 internal error).

### G.4 Flow 1 — being reachable ("permanent protocol submode", like Syncthing's relay listener)

1. Connect (G.2). Send `JoinRelayRequest{Token}`.
2. Read one message: `Response{0}` ⇒ joined; `Response{2}` ⇒ your ID is
   already joined elsewhere; `Response{3}` wrong token; `RelayFull` ⇒ pick
   another relay. The relay closes you if you have not joined within one
   `pingInterval` (default 1 min).
3. Keep-alive: **the relay sends `Ping` every `pingInterval` (1 min)** and you
   MUST answer `Pong`; the relay drops you after `networkTimeout` (2 min)
   without any message. Syncthing's client (`static.go`) only *answers*
   pings; it also times out itself if it hears nothing for 2 min
   (`messageTimeout`). You may additionally send Pings (the relay answers Pong).
   Docs say "the client fails to send a message … every minute" — the source
   shows the relay drives the pinging.
4. When someone wants you: you receive `SessionInvitation{From = their ID,
   Key = 32 random bytes, Address, Port, ServerSocket = true}`. Go to G.6.
5. `RelayFull` at any time ⇒ the relay is dropping you.
6. Announce `relay://host:port/?id=<RELAY-ID>` as one of your addresses
   (discovery, ClusterConfig) so peers know to use this relay.

### G.5 Flow 2 — connecting to a peer ("temporary protocol submode")

1. Connect (G.2) to the relay named in the peer's `relay://` address.
2. Send `ConnectRequest{ID = peer's 32-byte device ID}`.
3. Read one message: `SessionInvitation{From = peer ID, Key, Address, Port,
   ServerSocket = false}` ⇒ go to G.6; `Response{1 not found}` ⇒ peer not on
   this relay; `RelayFull`. Then close this TLS connection (the relay closes
   it too). Syncthing uses a 10 s timeout for the whole step.

The relay simultaneously pushes the mirror invitation to the joined peer
(`GetServerInvitationMessage`: `From = your ID`, a *different* 32-byte key,
`ServerSocket = true`). The two keys identify the two halves of one session.

### G.6 Session mode (plain TCP) and the BEP handshake inside it

1. Plain TCP (no TLS) to `Address:Port` from the invitation (10 s timeout).
2. Send `JoinSessionRequest{Key}` (framed with the same 12-byte header).
3. Read `Response`: `0` ⇒ joined; `1` ⇒ bad key; `2` ⇒ session full;
   `RelayFull` ⇒ give up. The relay buffers bytes until the other side joins.
4. From now on the socket is a transparent byte pipe to the peer. Start TLS
   **over this socket** with the normal BEP `tls.Config` (ALPN `bep/1.0`, TLS
   1.3, your cert): if `ServerSocket == true` you are the **TLS server**
   (`tls.Server`), if `false` you are the **TLS client** (`tls.Client`). The
   requester (ConnectRequest side) therefore always ends up as TLS client and
   the joined/listening side as TLS server. Then proceed exactly as for a
   direct connection: validate the peer's certificate hash against the
   expected device ID, exchange Hello, ClusterConfig, …
5. The relay kills a session after `networkTimeout` (2 min) with no data in
   either direction — BEP's 45–90 s Ping keeps it alive.

---

## H. What a vanilla Syncthing peer expects from a partial / read-mostly client

Sources: `lib/model/indexhandler.go`, `lib/model/model.go`, `lib/model/folder_sendrecv.go`
(URLs in A/B), plus syncthing-lite:
- https://raw.githubusercontent.com/syncthing/syncthing-lite/master/syncthing-bep/src/main/kotlin/net/syncthing/java/bep/connectionactor/Instance.kt
- https://raw.githubusercontent.com/syncthing/syncthing-lite/master/syncthing-bep/src/main/kotlin/net/syncthing/java/bep/connectionactor/ClusterConfigHandler.kt
- https://raw.githubusercontent.com/syncthing/syncthing-lite/master/syncthing-bep/src/main/kotlin/net/syncthing/java/bep/BlockPusher.kt
- https://raw.githubusercontent.com/syncthing/syncthing-lite/master/syncthing-bep/src/main/kotlin/net/syncthing/java/bep/RequestHandlerRegistry.kt

**Partial index is fine.** Syncthing has no notion of "this device has no local
copy"; there is no folder flag for it. Its model is: whatever you list in your
Index is what you have; anything the global model has that you did not list is
simply "needed by you" — the peer shows you as N% "out of sync" in its GUI and
does nothing else (it never pushes; the puller is always on the receiving
device). An **empty `Index`** (`folder` set, zero files) is legal and is what
syncthing-lite sent: after ClusterConfig it sent `Index{folder}` with no
files for every shared folder and thereafter only `IndexUpdate`s for files it
uploaded (`Instance.kt:141-150`, "send index messages - TODO: Why?"). You can
also send **no Index at all**: Syncthing drops everything it knew about you
(if you announced `index_id = 0`) and treats your folder as empty; it will
still send you its full index and answer your Requests. Not sending an Index
just means the peer keeps whatever it stored from a previous session when you
announce the same non-zero `index_id` — so announce `index_id = 0` unless you
persist.

syncthing-lite's ClusterConfig (`ClusterConfigHandler.kt`): `Folder{id, label}`
with default `type` (send-receive), no flags, exactly two `Device`s — itself
(`id`, `index_id`, `max_sequence`) and the peer (`id`, plus the stored
`index_id`/`max_sequence` of the peer when known). It set no `compression`,
`name`, `addresses`, `cert_name`. This was accepted by Syncthing v0.14–v1.x
and matches what v2 still requires (both device entries present).

Uploading from a partial client (syncthing-lite `BlockPusher.sendIndexUpdate`):
one `IndexUpdate` with a single FileInfo — `name`, `type`, `size`, `blocks`,
`block_size`, `sequence = next local seq`, `version = old counters + Counter{id
= myShortID, value = next local seq}`, `modified_s/ns = now`, `no_permissions =
true`; then it served the peer's Requests for those blocks from memory. Note
the `Counter.value` should be `max(old+1, unixNow)` to interoperate with
Syncthing's clock-based counters (C) — lite's per-upload sequence also works
because any strictly greater value wins, but a value below Syncthing's
timestamp-valued counter for the same device id would look older.

Serving Requests you cannot satisfy: return `NO_SUCH_FILE (2)` for "I do not
have that file/block" (this is what Syncthing itself returns for a missing
file, a bad offset, or a hash mismatch), `INVALID_FILE (3)` for "exists but I
refuse/it is invalid", `GENERIC (1)` for internal errors and unknown folders.
syncthing-lite answered `GENERIC` for anything without a registered upload
listener. The requesting Syncthing reacts identically to all three (H above,
A.5): it tries another device that advertises the block, and fails the pull
for this round if none is left; it never disconnects and never blacklists you.
Because a Syncthing peer only requests blocks that YOUR index advertises, a
client that lists only the files it really holds will receive no unsatisfiable
Requests at all.

If you list files with `invalid = true` the peer never requests them and does
not count them against completion.

---

## I. Folder types, IDs, markers, and on-disk names to ignore

Sources:
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/config/folderconfiguration.go
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/versioner/util.go
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/fs/filesystem.go , `.../lib/fs/tempname.go`
- https://raw.githubusercontent.com/syncthing/syncthing/main/gui/default/syncthing/core/syncthingController.js (`addFolder`)
- https://raw.githubusercontent.com/syncthing/syncthing/main/lib/rand/random.go
- https://docs.syncthing.net/specs/bep-v1.html#sharing-modes

- **Folder types** (config `type`): `sendreceive` (default), `sendonly`,
  `receiveonly`, `receiveencrypted`. All are local policies (A.7). Send-only:
  never applies remote changes (GUI offers "Override"). Receive-only: applies
  remote changes; local changes are kept but advertised as `invalid` with an
  empty version (GUI offers "Revert"). On the wire the folder `type` enum is
  informational.
- **Folder ID**: any string; the GUI default is `rand.String(10)` lower-cased
  and split `xxxxx-xxxxx` (e.g. `k7pq2-3mdfa`), alphabet
  `2345679abcdefghijkmnopqrstuvwxyzACDEFGHJKLMNPQRSTUVWXYZ` before lower-casing.
  The `id` must match exactly on all devices; `label` is free text.
- **Marker**: directory `.stfolder/` at the folder root (`DefaultMarkerName`),
  hidden on Windows; since v2 it contains `syncthing-folder-<first 3 bytes of
  sha256(folderID) as 6 hex chars>.txt` with a comment header and `folderID:
  <id>`. Syncthing refuses to run a folder whose marker is missing. Custom
  `markerName` may point at another path.
- **Ignore patterns**: `.stignore` at the folder root (plus `#include`d files,
  and `.stglobalignore`). Never synced.
- **Versions**: `.stversions/` at the folder root (`versioner.DefaultPath`),
  when a versioning scheme is enabled. Never synced.
- `fs.IsInternal` treats exactly `.stfolder`, `.stignore`, `.stversions` (and
  anything under them) as internal: they are never indexed and a Request for
  them gets `INVALID_FILE`.
- **Temp files**: in-progress downloads are `.syncthing.<name>.tmp` (Unix) or
  `~syncthing~<name>.tmp` (Windows) beside the target; `from_temporary`
  Requests read them. Skip names with these prefixes when scanning.
- Conflict copies: `<base>.sync-conflict-<date>-<time>-<SHORTID><ext>`; these
  ARE synced as ordinary files.
- **File type enum**: `FILE = 0`, `DIRECTORY = 1`, `SYMLINK = 4` (2 and 3 are
  deprecated symlink variants; read them as SYMLINK). Directories have `size
  0`, no blocks; symlinks have `size 0`, `symlink_target` (bytes).
- Default TCP/QUIC port 22000; local discovery UDP 21027; relay server TCP
  22067 (status HTTP 22070).

---

## J. Encoding recaps for a hand-written codec

### J.1 Protocol Buffers (proto3) wire format

Source: https://protobuf.dev/programming-guides/encoding/ (general spec, not
Syncthing-specific). Everything BEP uses is covered by:

- A message is a sequence of `(tag, value)` records. `tag = varint((field_number << 3) | wire_type)`.
- Wire types: `0` VARINT (int32, int64, uint32, uint64, bool, enum), `1` I64
  (fixed64/double — unused by BEP), `2` LEN (string, bytes, embedded message,
  packed repeated scalars), `5` I32 (fixed32/float — unused). Types 3/4 are
  obsolete groups; treat as an error.
- **varint**: little-endian base-128; each byte holds 7 bits, MSB = "more
  follows"; up to 10 bytes. `int32`/`int64` negatives are encoded as the
  two's-complement **64-bit** value (so a negative int32 is 10 bytes). `bool`
  is `00`/`01`. Enums are their integer value. (`sint*` zigzag is not used in
  any Syncthing proto.)
- **LEN**: `varint length` then exactly `length` bytes. `string` is UTF-8;
  `bytes` raw; an embedded message is its own encoding nested. A zero-length
  LEN record is valid (e.g. `Index{folder:"x", files:[]}` has no `files` tags
  at all; an empty `Ping` is 0 bytes).
- **repeated message fields** (`folders`, `devices`, `files`, `blocks`,
  `counters`, `updates`, `xattrs`, `addresses` strings): one LEN record per
  element, tag repeated; order preserved.
- **repeated scalar fields**: proto3 default is *packed* — a single LEN record
  whose payload is the concatenated varints. The only repeated scalar in BEP,
  `FileDownloadProgressUpdate.block_indexes`, is declared `[packed = false]`
  so Syncthing emits one VARINT record per element. A decoder must accept
  both forms for a repeated scalar (the spec requires it); an encoder should
  emit unpacked here.
- **Defaults / omission**: a field equal to its default (0, false, "", empty
  bytes, empty repeated, unset message) is not written; when reading, a missing
  field means the default. Never rely on presence. Note an empty *message*
  field (`platform`) may still appear as a zero-length LEN record if the
  sender allocated it; treat both the same.
- **Unknown fields**: skip by wire type (varint: read it; LEN: read length and
  skip; I64: 8 bytes; I32: 4 bytes). Field 1000/1001/1003 of FileInfo may
  appear from odd senders — skip them.
- **Duplicates / order**: fields may appear in any order; for a non-repeated
  field the last occurrence wins; for embedded messages later occurrences are
  merged (Syncthing's own encoder writes each field once, in field-number
  order for the message, so you will not see this from it).
- Maximum sizes: Header body must fit in `uint16`; message body ≤ 500 000 000.

Worked example — `Header{type: INDEX, compression: LZ4}` = `08 01 10 01`
(field 1 varint 1; field 2 varint 1), framed as `00 04 08 01 10 01 <len32> …`.
`Counter{id: 0x0102030405060708, value: 1}` = `08 88 8E 98 A8 C0 E0 80 81 01 10 01`
(12 bytes: tag `08`, 9-byte varint of the uint64 id, tag `10`, varint `01`).
Wrapped as `Vector{counters:[that]}` it becomes `0A 0C` + those 12 bytes.

### J.2 LZ4 block format (needed to decode incoming compressed messages)

Source: https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md (the
block format; pierrec/lz4 `CompressBlock`/`UncompressBlock` implement exactly
this with no frame). Decoding a block of `src` into `dst` of the known
uncompressed size (the 4-byte BE prefix Syncthing adds):

```
loop:
  token = src[i++]
  litLen = token >> 4
  if litLen == 15: repeat { b = src[i++]; litLen += b } while b == 255
  copy litLen literal bytes src[i..] → dst; i += litLen
  if i == len(src): done                      (last sequence has literals only)
  offset = src[i] | src[i+1] << 8  (LE uint16, 1..65535; 0 is invalid); i += 2
  matchLen = (token & 0x0F) + 4
  if (token & 0x0F) == 15: repeat { b = src[i++]; matchLen += b } while b == 255
  copy matchLen bytes from dst[pos - offset] to dst[pos], byte by byte
  (overlap allowed and common: offset may be < matchLen)
```

Validate: `pos - offset >= 0`, never write past `uncompressedLen`, and the
final `pos == uncompressedLen`. Encoder-side constraints (irrelevant to a
decoder that never compresses): min match 4, last 5 bytes are literals, last
match ends ≥ 12 bytes before block end.

---

## K. Summary of v1 → v2 wire changes (all backwards compatible)

Commit list for `proto/bep/bep.proto` (https://api.github.com/repos/syncthing/syncthing/commits?path=proto/bep/bep.proto):

| Date | Commit | Change |
| --- | --- | --- |
| 2024-12-01 | 77970d5113 | gogo-protobuf → `google.golang.org/protobuf`; proto moved from `lib/protocol/bep.proto` to `proto/bep/bep.proto`, generated code to `internal/gen/bep`; **no wire change** (v1.29.0). Enum value names gained prefixes (`MESSAGE_TYPE_…`, `FILE_INFO_TYPE_…`, `ERROR_CODE_…`) — names only. |
| 2025-01-11 | 516f3e29e8 | `FileInfo.symlink_target` string → bytes (same wire type 2; allows non-UTF-8 targets). |
| 2025-03-29 | b1c8f88a44 | Weak hash removed: `BlockInfo.weak_hash` (4) and `Request.weak_hash` (8) → `reserved`. (v2.0.0) |
| 2025-06-29 | 95187bcc64 | `Folder.read_only` (3) → `FolderType type` (3); `Folder.paused` (7) → `FolderStopReason stop_reason` (7); fields 4–6 (`ignore_permissions`, `ignore_delete`, `disable_temp_indexes`) reserved. (v2.0.0) |
| 2025-09-13 | d037681fd1 | `FileInfo.previous_blocks_hash = 20` added (conflict detection). |
| 2026-03-23 | b39c56f82d | `FileInfo.inode_change_ns` (1002) removed → reserved (was DB-only anyway). |

Also v2.0.0: device certificates are generated with Ed25519 instead of ECDSA
P-384 (`lib/tlsutil/tlsutil.go`); existing certs keep working. TLS 1.3 has
been the BEP minimum since v1.x (`SecureDefaultTLS13`). The database moved to
SQLite in v2 (irrelevant on the wire). Hello fields 4–5, `ClusterConfig.secondary`,
`Index.last_sequence`, `IndexUpdate.prev_sequence` and multi-connection
support arrived during v1.2x and are absent from the docs.

---

## Sources used

Specs (docs.syncthing.net, "Written for v2.1.0"):
- https://docs.syncthing.net/specs/bep-v1.html
- https://docs.syncthing.net/specs/globaldisco-v3.html
- https://docs.syncthing.net/specs/localdisco-v4.html
- https://docs.syncthing.net/specs/relay-v1.html
- https://docs.syncthing.net/dev/device-ids.html

syncthing/syncthing `main` (raw.githubusercontent.com/syncthing/syncthing/main/…):
- proto/bep/bep.proto
- proto/discoproto/local.proto
- proto/discosrv/discosrv.proto
- lib/protocol/protocol.go, bep_hello.go, bep_clusterconfig.go, bep_fileinfo.go, bep_index_updates.go, bep_request_response.go, bep_download_progress.go, errors.go, vector.go, deviceid.go, luhn.go, indexid.go, wireformat.go, counting.go
- lib/tlsutil/tlsutil.go
- lib/syncthing/syncthing.go, lib/syncthing/utils.go
- lib/connections/service.go, tcp_dial.go, tcp_listen.go, quic_dial.go, quic_listen.go, quic_misc.go, relay_dial.go, relay_listen.go, structs.go, util.go
- lib/scanner/blocks.go
- lib/model/model.go, indexhandler.go, folder_sendrecv.go
- lib/discover/global.go, local.go, discover.go
- lib/beacon/broadcast.go, multicast.go
- lib/relay/protocol/packets.go, packets_xdr.go, protocol.go
- lib/relay/client/client.go, static.go, methods.go, dynamic.go
- lib/config/config.go, folderconfiguration.go, optionsconfiguration.go
- lib/fs/filesystem.go, lib/fs/tempname.go, lib/versioner/util.go, lib/ignore/ignore.go, lib/rand/random.go
- cmd/stdiscosrv/apisrv.go, cmd/stdiscosrv/main.go
- cmd/strelaysrv/main.go, listener.go, session.go
- gui/default/syncthing/core/syncthingController.js
- Git history: https://api.github.com/repos/syncthing/syncthing/commits?path=proto/bep/bep.proto ; https://api.github.com/repos/syncthing/syncthing/commits/95187bcc64
- Tag v1.29.7: proto/bep/bep.proto, lib/tlsutil/tlsutil.go, lib/relay/protocol/packets.go (https://raw.githubusercontent.com/syncthing/syncthing/v1.29.7/…)
- Tag list: https://api.github.com/repos/syncthing/syncthing/tags

Other:
- https://raw.githubusercontent.com/calmh/xdr/master/marshaller.go , unmarshal.go , common.go
- https://relays.syncthing.net/endpoint
- syncthing/syncthing-lite `master`: syncthing-bep/src/main/kotlin/net/syncthing/java/bep/connectionactor/Instance.kt, ClusterConfigHandler.kt, HelloMessageHandler.kt, PostAuthenticationMessageHandler.kt, BlockPusher.kt, RequestHandlerRegistry.kt (https://raw.githubusercontent.com/syncthing/syncthing-lite/master/…)
- https://protobuf.dev/programming-guides/encoding/ (protobuf wire format, general)
- https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md (LZ4 block format, general)
