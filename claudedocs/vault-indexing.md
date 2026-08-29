# Luna Vault v1 on-device indexing

Vault indexing is intentionally a local-only pipeline. `LunaVaultIndexExtraction`
does not import `URLSession`, a backend, or a provider SDK. Text is routed by
the filename/content type and conservative magic-byte checks. Plain text,
Markdown, HTML, RTF, PDF, DOCX, and EPUB produce bounded chunks. Images use an
injected Vision OCR adapter and audio/video use an injected on-device Speech
adapter. Protected documents, archives, and unknown binary formats remain
metadata-only; no archive is unpacked during indexing.

The default extraction policy accepts a declared object size up to 100 GB but
keeps in-memory extraction bounded to 64 MiB, text to 16 MB, and indexing to
8,000 chunks, 1,200 characters per
chunk, and a 30-second work budget. DOCX/EPUB central directories are preflighted
before decompression for entry count, per-entry and total expanded bytes, ZIP64,
encryption, and compression ratio. Images are metadata-inspected without decoding,
checked for compressed/pixel/decoded-byte limits, and downsampled before Vision.
Videos are never handed to Speech: AVFoundation exports their audio track into a
bounded Data-Protected temporary M4A first. Production composition must supply an
on-device Vision/Speech implementation where the OS model is available. The
default embedding generator fails with `modelUnavailable`; it never downloads
or calls a server. `DeterministicVaultEmbeddingGenerator` exists only for test
fixtures and migration tests, and every vector carries model version, dimension,
and SHA-256 checksum.

`VaultExtractionPipeline` validates a schema-tagged/checksummed artifact before
parsing, keys cached results by object/revision/model version, and atomically claims
an idempotent Stage 2 index-job lease. Success, retry, failure, and cancellation
are transitioned by the lease owner. The storage adapter persists the serialized result in
`vault.sqlite`'s `extraction_artifacts` table. Revisions or model updates
therefore cause a new extraction without duplicating work on retries. Cancellation
is checked before and after model work; retry policy and leases remain owned by
the Stage 2 job queue. Speech output is stored as timestamped segments so search
results can seek to the matching spoken words. All encrypted PDFs are rejected in
v1 because there is no explicit credential/unlock flow.

Run the focused package compile with:

```sh
swift build --package-path LunaLibraries --target LunaVaultIndexExtraction
swift build --package-path LunaLibraries --target LunaVaultEmbeddings
```

The iOS test host includes `VaultExtractionTests.swift`; run the normal `Luna`
scheme on an iOS 26 simulator using the recipe in `AGENTS.md`. Tests inject all
OCR, Speech, metadata, and artifact implementations, so fixture tests never
open a network connection.
