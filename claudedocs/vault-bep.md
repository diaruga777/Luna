# Vault BEP implementation

`LunaVaultBEP` implements the interoperable subset of Syncthing Block Exchange
Protocol v1 used by Luna Vault. The authoritative byte-level reference is
`claudedocs/vault-bep-reference.md`.

The transport hands the module a mutually authenticated, plaintext byte stream.
Both peers send the 0x2EA7D90B Hello magic and exchange protobuf Hellos before
the message loop starts. Each direction must send `ClusterConfig` first.

Message frames use a big-endian header length, protobuf `Header`, big-endian
body length, and a protobuf body. Incoming LZ4 bodies are raw LZ4 blocks with a
four-byte uncompressed length; Luna sends uncompressed messages, but always
decodes peer compression. Unknown message types are consumed and ignored.

`BEPConnection` owns ordering, request response matching, concurrent request
serving, ping/receive timers, and close propagation. A failed write tears down
its session immediately; a courtesy Close write has a one-second deadline so
a stalled socket cannot block reconnect. Delegates handle folder
policy and block bytes. Tests should use `PipeByteStream` rather than sockets.

File names are folder-relative normalized paths. A non-deleted regular file
must advertise at least one block, including the zero-length block for an empty
file. Block responses are SHA-256 checked before cache installation.

`BEPBlockTransfer` drives a rolling window of at most eight block requests,
limited to 32 MiB of requested payload by the largest block size. Completed
blocks are verified and written at their offsets, then the next request starts
without waiting for the rest of a batch. Both Mac uploads and iPhone downloads
use it. Files become visible only after every block verifies and the final
synchronize succeeds.

Between initial index exchanges the iPhone announces pending local changes
only. It does not re-announce confirmed cached files on each import: that made
the companion re-hash previous large uploads before requesting the next file.
Block serving checks one stored hash directly and updates cache access at most
once per 30 seconds instead of rebuilding all block descriptors and writing
SQLite for every block. An initial-index timeout closes the incomplete session
so subsequent reconnects cannot keep reusing a session stuck in `syncing`.
