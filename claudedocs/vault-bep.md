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
serving, ping/receive timers, and close propagation. Delegates handle folder
policy and block bytes. Tests should use `PipeByteStream` rather than sockets.

File names are folder-relative normalized paths. A non-deleted regular file
must advertise at least one block, including the zero-length block for an empty
file. Block responses are SHA-256 checked before cache installation.
