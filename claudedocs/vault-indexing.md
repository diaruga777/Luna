# Luna Vault v1 on-device indexing

Vault indexing is intentionally a local-only pipeline. `LunaVaultIndexExtraction`
does not import `URLSession`, a backend, or a provider SDK. Text is routed by
the filename/content type and conservative magic-byte checks. Plain text,
Markdown, HTML, RTF, PDF, DOCX, and EPUB produce bounded chunks. Images use an
injected Vision OCR adapter and audio/video use an injected on-device Speech
adapter. Protected documents, archives, and unknown binary formats remain
metadata-only; no archive is unpacked during indexing.

The default extraction policy accepts a declared object size up to 100 GB but
keeps indexing bounded to 16 MB of text, 8,000 chunks, 1,200 characters per
chunk, and a 30-second work budget. Production composition must supply an
on-device Vision/Speech implementation where the OS model is available. The
default embedding generator fails with `modelUnavailable`; it never downloads
or calls a server. `DeterministicVaultEmbeddingGenerator` exists only for test
fixtures and migration tests, and every vector carries model version, dimension,
and SHA-256 checksum.

`VaultExtractionPipeline` checks the artifact store before parsing, keys cached
results by object/revision/model version, and schedules an idempotent Stage 2
index job. The storage adapter persists the serialized result in
`vault.sqlite`'s `extraction_artifacts` table. Revisions or model updates
therefore cause a new extraction without duplicating work on retries. Cancellation
is checked before and after model work; retry policy and leases remain owned by
the Stage 2 job queue.

Run the focused package compile with:

```sh
swift build --package-path LunaLibraries --target LunaVaultIndexExtraction
swift build --package-path LunaLibraries --target LunaVaultEmbeddings
```

The iOS test host includes `VaultExtractionTests.swift`; run the normal `Luna`
scheme on an iOS 26 simulator using the recipe in `AGENTS.md`. Tests inject all
OCR, Speech, metadata, and artifact implementations, so fixture tests never
open a network connection.
