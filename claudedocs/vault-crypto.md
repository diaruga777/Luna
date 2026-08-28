# Luna Vault cryptography

Vault keeps the root key in one synchronizable Keychain generic-password item
(a service derived from the configured Luna namespace, account `default`, Vault access group,
`kSecAttrSynchronizable=true`, `kSecAttrAccessibleWhenUnlocked`). A missing or
malformed item is an explicit recovery error; the app never creates a replacement
without the setup flow asking the user. The serialized value is a JSON key ring
containing 256-bit keys, monotonically increasing versions, and SHA-256
fingerprints. Rotation appends a new version and old versions remain available
for rewrapping existing objects. Decoding rejects empty or oversized rings,
zero/duplicate/out-of-order versions, non-32-byte keys, and fingerprints that
do not recompute. Rotation rejects an exhausted `UInt32` version space.
`createFirstRun` is the only creation entry point; normal
launch calls `loadRequired` and enters recovery if iCloud Keychain has not yet
restored the item. Creation uses an atomic Keychain add so racing setup callers
converge on one key. Reset deletes only this Vault descriptor after explicit
confirmation.
Root creation, rotation, and reset are also serialized with a zero-byte lock
file in the App Group. The lock carries no key material; it only prevents two
Vault host processes from losing a Keychain ring update. The initial Keychain
write still uses `SecItemAdd`, so creation remains atomic if the lock file is
lost or recreated.

Each object receives a random 256-bit DEK. The DEK is wrapped by AES-GCM under
the selected root version. Its versioned frame binds the vault, object, revision,
and root version before attempting unwrap. Content, metadata, and index artifacts use the same
versioned chunk envelope: magic/version, role, root version, opaque object UUID,
revision UUID, chunk index, total plaintext length, 12-byte nonce, ciphertext and
16-byte authentication tag. AAD includes vault domain, role, root version, object,
revision, chunk index, and plaintext length. This binds ranges and prevents a
chunk from being moved between objects, revisions, or artifact types. No padding
or cross-file deduplication is performed.

The `VaultChunkedCryptor` accepts an injected random source for deterministic
tests; production randomness comes from CryptoKit's CSPRNG. It rejects duplicate
nonces within one seal, caps both encoded and decoded objects at 100 GB and chunks at 8 MiB, validates every frame's
exact length/count/order/version and consistent identity before allocation, and
provides authenticated `openRange` reads. Even an empty range authenticates the
complete envelope before returning. The vault identifier is length-bound
inside AAD, so even two local vaults with matching object UUIDs cannot exchange
chunks. Remote transports must only receive the encoded
envelopes and opaque IDs; plaintext names, metadata, indexes, and key material
must never be logged or sent.
