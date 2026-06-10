# Photo Search

On-device, natural-language search over the device photo library. This **is** the
clip app — it is the root experience, fully self-contained, no login, no camera.

## Entry point

- `AppDelegate` configures a single `SceneDelegate`.
- `SceneDelegate.makeContext()` builds the `PhotoSearchContext` (CLIP + photo index +
  VLM + applets) and sets `PhotoSearchRootViewController` as the window root.

## How it works

CLIP-style dual-encoder retrieval. The image encoder and text encoder map photos
and the query into one shared 512-d space; results are **filtered** to photos
whose raw cosine similarity clears a floor (`semanticRelevanceFloor`, 0.15) or
that match OCR text, then ranked. A non-embedding **Apple Vision baseline**
(`appleVision`) is also selectable for comparison: no CLIP, just `VNClassifyImage`
labels + OCR matched as text.

Pipeline: pick model → (download/compile encoders, or use bundled/system) → index
photo library (analyze each photo → embedding + searchable text) → persist a flat
index → search live, per keystroke.

### Search latency (the product depends on this)
Per-keystroke path, optimized end to end:
- **Debounce** 50 ms (coalesces bursts).
- **Text embedding**: cached per query (LRU 128) in `CoreMLCLIPEmbeddingEngine`, so
  backspace/retype is free; the engine instance is reused across screen appearances
  (`PhotoSearchContext.makeEngine` caches by model) so the Core ML model stays loaded.
  On device the encoder runs on the ANE (a few ms); the cache removes repeats.
- **Lookup**: one `cblas_sgemv` over the whole matrix → ~1.6 ms at 50k photos.
- **UI**: results capped at 500 → bounded diffable snapshot diff; `animatingDifferences: false`.
- **Images**: `PHCachingImageManager` with `.fastFormat`, one consistent thumbnail
  size, prewarm of the first 30 results + `UICollectionViewDataSourcePrefetching`.

### Models (all hardcoded, verified applicable today)
- **MobileCLIP-S0 / S1 / S2 / B-LT** — downloaded from `apple/coreml-mobileclip`
  (pinned SHA), compiled at runtime. CLIP-BPE dual encoders.
- **MobileCLIP2-S0** — bundled (no published Core ML export; converted via
  `scripts/convert_mobileclip2_coreml.py`, int8, Git LFS). **Default.**
- **Apple Vision (on-device)** — `source .system`, no embeddings; closed-vocab
  labels + OCR. Comparison baseline.

> Simulator: int8 CLIP models return all-zero outputs on the GPU/ANE path, so the
> engine forces `computeUnits = .cpuOnly` under `targetEnvironment(simulator)` and
> `.all` (ANE) on device.

## Key files (`Clip/PhotoSearch/`)

| File | Role |
|---|---|
| `CLIPModel.swift` | `enum CLIPModel` with `Source` (`huggingFace` / `bundled` / `system`); S0/S1/S2/B-LT (HF), MobileCLIP2-S0 (bundled), `appleVision` (system). dim 512 (0 for Vision), context 77. HF repo `apple/coreml-mobileclip` (pinned SHA). |
| `CLIPModelStore.swift` | UserDefaults selection (`photoSearchClipModel`), default MobileCLIP2-S0. |
| `CLIPModelManager.swift` | HF models: download each `.mlpackage` (file list via HF tree API; surfaces `{error}` payloads), compile to `.mlmodelc` in App Support. Bundled: load from app bundle. System: always available. |
| `CLIPTextTokenizer.swift` | `BPECLIPTokenizer` — faithful OpenAI CLIP byte-level BPE; merges from bundled `clip_merges` asset-catalog data set (48,894 rules → 49,408 vocab). |
| `CLIPEmbeddingEngine.swift` | `CoreMLCLIPEmbeddingEngine` actor; discovers image/text/output feature names; image via `MLFeatureValue(cgImage:constraint:)` (Core ML resizes/normalizes), int32 `[1,77]` tokens for text; L2-normalizes. `.cpuOnly` on simulator, `.all` on device. |
| `CLIPEngineProvider.swift` | `model → CLIPEmbeddingEngine?` (nil for non-CLIP/not-ready); lazy bundled tokenizer. |
| `PhotoFrameAnalyzer.swift` | Per-photo analysis seam: `CLIPFrameAnalyzer` (image embedding + OCR) vs `VisionFrameAnalyzer` (`VNClassifyImageRequest` labels + OCR, embedding []). `PhotoFrameAnalyzerProvider` picks by `model.source`. |
| `PhotoSearchDiagnostics.swift` | Launch-arg self-test (`-photoSearchSelfTest YES`): embeds solid red/blue + text, logs cosines on the real runtime. |
| `PhotoEmbeddingIndex.swift` | `PhotoIndexEntry {localIdentifier, embedding, ocrText, creationDate}`, `PhotoEmbeddingIndex {modelIdentifier, embeddingDimension, entries}`. |
| `PhotoIndexStore.swift` | Flat **binary plist** at `PhotoSearchIndex/index.plist` (App Support), atomic, backup-excluded. **No DB** (per project rule). |
| `PhotoIndexer.swift` | Enumerate `PHAsset`s → bounded-concurrency (3) load + `analyzer.analyze` → merge. `force` rebuilds; else incremental (adds new, prunes deleted). Cancellable; partial-saves. Switching model invalidates the index. |
| `PhotoSearchService.swift` | Actor. `search` = blank → reverse-chronological; else keep entries above the cosine floor or with OCR/label match, ranked by fused score `0.7·semanticₙ + 0.3·ocr + (exactPhrase ? 1.0 : 0)`. Dimension-0 (Vision) index = text-only matching. Cosine via one Accelerate `cblas_sgemv` (all N dot-products in one call); results capped to `maxResults` (500). ~1.6 ms over 50k photos. |
| `PhotoAssetSource.swift` | `PhotoKitAssetSource` (fetch + `PHImageManager` load) behind a protocol seam for tests. |
| `ImageTextRecognizer.swift` | `VisionImageTextRecognizer` (`VNRecognizeTextRequest`, accurate). |
| `PhotoLibraryAuthorizing.swift` | `.readWrite` authorization wrapper. |
| `Mock*.swift` | Deterministic engine, fake asset source/OCR, mock provider/authorizer, test-image factory. |

## View controllers (`Clip/ViewControllers/PhotoSearch/`)

- `PhotoSearchRootViewController` — `UINavigationController`; grid is the main
  page, setup behind a toolbar button; routes to setup on first launch (no index).
- `PhotoSearchModelViewController` — model picker + download progress; "Process
  Photo Library" (incremental) / "Reprocess All" (force) with progress + cancel;
  photo-permission flow (denied → Open Settings).
- `PhotoSearchGridViewController` — `UISearchController` + compositional 3-col
  grid; debounced (180ms) per-keystroke search with a single cancellable task;
  blank query = chronological; `PHCachingImageManager` thumbnails.
- `PhotoGridCell` / `PhotoPreviewViewController` — thumbnail cell (cancels stale
  requests) / full-image preview.
- `PhotoSearchContext` — shared deps + the one `PhotoSearchService` instance.

## Permissions

`INFOPLIST_KEY_NSPhotoLibraryUsageDescription` (already declared in build
settings) covers read access.

## Tests (`PouchTests/PhotoSearch/`)

Tokenizer (length/sentinels/truncation/determinism), index store round-trip,
search ranking (semantic, OCR exact-phrase boost, nil-embedding OCR fallback,
chronological), indexer (force/incremental/prune, model-switch invalidation,
empty library, OCR capture, model-not-ready). PhotoKit + Core ML are mocked via
the protocol seams; the real Core ML path is validated on device.

## Models

| Model | Source | Notes |
|---|---|---|
| MobileCLIP-S0 / S2 | HuggingFace `apple/coreml-mobileclip` (pinned SHA), downloaded + compiled at runtime | Default. v1 Core ML exists. |
| MobileCLIP2-S0 | **Bundled** (`CLIPModel.Source.bundled`) | No published Core ML export — generated by `scripts/convert_mobileclip2_coreml.py`. |

### MobileCLIP2 (bundled)
MobileCLIP2 has no Core ML export on HuggingFace (only PyTorch + community ONNX).
`scripts/convert_mobileclip2_coreml.py` converts an OpenCLIP MobileCLIP2 variant
to two `.mlpackage` encoders. They live in `Clip/PhotoSearch/Models/` and Xcode
compiles them into `clip_image_s0.mlmodelc` / `clip_text_s0.mlmodelc` in the app
bundle; `CLIPModelManager` loads them via `Bundle.main`. If absent, the model
shows as "unavailable" in the picker (no-op, points at the script).

The int8-quantized S0 encoders (~72 MB) are committed via **Git LFS** (see
`Clip/PhotoSearch/Models/.gitattributes`) — run `git lfs install` before cloning
/ pulling, or the `.mlpackage` weight blobs arrive as pointer files and the CoreML
build step fails. Validated on macOS: text torch↔CoreML cosine parity ≈1.0, image
≈0.97; a dog photo scores 0.22 to "a dog" vs 0.11 to "a car". The compiled
`.mlmodelc` load via `MLModel(contentsOf:)` with IO `image`/`tokens` → `embedding`
(512-d). MobileCLIP2-S0 is the **default** model; it needs no download but does
need the LFS blobs (else the picker shows it unavailable and the user must pick a
downloadable v1 variant).

## Known limits / TODO

- MobileCLIP2 weights are committed via Git LFS; cloners need `git lfs install`
  or the CoreML build step fails on pointer files.
- Image preprocessing is handled by Core ML via `MLFeatureValue(cgImage:constraint:)`
  (verified: MobileCLIP normalization is mean 0 / std 1, i.e. just `/255`).
- No video yet (images only).
- No login required — verified launching straight into the setup screen on the
  simulator with MobileCLIP2-S0 bundled + selected.
