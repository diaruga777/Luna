# Applets

User-defined rules over captured photos: **[If a photo contains X] THEN [count it
+ optionally notify]**. Built on top of the [Photo Search](photo-search.md) CLIP
index. Lives inside the Photo Search experience (wand button on the photo grid).

## Rule shape

`Applet` (`Clip/PhotoSearch/Applets/Applet.swift`): `id`, `name`, `query` (the
"contains X" string), `createdAt`, `captureCount`, `notifyOnCapture`, `threshold`
(generous CLIP gate, default `0.22`), `matchedAssetIdentifiers` (dedupe set so an
asset is never counted twice). `Codable`.

## The two-step "contains" check

1. **CLIP gate (cheap):** embed `query` with the CLIP text encoder, cosine vs the
   photo's stored embedding; ≥ `threshold` → candidate.
2. **VLM confirm (final):** a local multimodal LLM answers a constrained yes/no on
   the full image. Only confirmed, not-yet-counted matches increment the count and
   (if `notifyOnCapture`) post a notification.

`AppletEvaluator` (`Clip/PhotoSearch/Applets/AppletEvaluator.swift`, actor) runs
this per photo, loading the full image lazily and only once a candidate clears the
gate. Caches query embeddings per query (engine is bound to one CLIP model).

## VLM (local multimodal LLM)

- `VLMModel` (`Clip/PhotoSearch/VLM/VLMModel.swift`): `smolVLM2_256M` (default,
  smallest), `smolVLM2_500M`, `fastVLM_0_5B`. Pinned HuggingFace **MLX** repos.
- `VLMModelManager` downloads whole-repo MLX snapshots (staged atomic move, mirrors
  `CLIPModelManager`) into App Group `VLMModels/<raw>/`. `VLMModelStore` persists
  the selection in the App Group `UserDefaults` suite.
- `VLMEngine.contains(image:query:)` → `MLXVLMEngine` (runs via **mlx-swift-examples
  2.29.1**: `VLMModelFactory.loadContainer` → `UserInput` → `generate`, parses a
  leading "yes"). `VLMEngineProvider` builds it from the selected model's dir;
  `MockVLMEngine` for tests.
- Picker UI: "Language Model · Applets" section in `PhotoSearchModelViewController`.
- **MLX requires a real device** (Metal); compiles for simulator but doesn't run
  there. App has `com.apple.developer.kernel.increased-memory-limit` (peak ~0.8–1.2GB).

## Ingest (process new photos)

`NewPhotoProcessor` (`Clip/PhotoSearch/Ingest/NewPhotoProcessor.swift`) is the
testable core: analyze (CLIP embed + OCR) → append to the shared index
(`PhotoIndexStore.appendEntry`, `NSFileCoordinator`-guarded) → `AppletEvaluator`.
One asset at a time; decoded image reused for analysis + VLM.

Driver:
- **Foreground:** `ForegroundPhotoIngestObserver` (`PHPhotoLibraryChangeObserver`,
  started by `PhotoSearchRootViewController`) — processes new photos while the app
  is open. No-ops unless a CLIP model + VLM are ready and an applet exists.

> The old `BackgroundResourceUploadExtension` (PhotoKit `PHBackgroundResourceUploadExtension`)
> was **removed** — it's a backup mechanism (opportunistic, breaks with iCloud Photos,
> `-1` errors in iOS 26.1/26.2), not a reliable trigger. For an instant, locked trigger
> see [[pocket-trigger]] (LockedCameraCapture + Camera Control button).

## Storage (App Group, shared with the future extension)

App Group `group.com.hpiddy.clip` via `AppGroup` (`Clip/Storage.swift`):
- Applets: `Applets/applets.plist` (`AppletStore`, `NSFileCoordinator`, NOT
  backup-excluded — user data).
- Photo index: `PhotoSearchIndex/index.plist` · CLIP encoders: `CLIPModels/` ·
  VLM checkpoints: `VLMModels/` · CLIP/VLM selection: App Group `UserDefaults`.

## Backfill on create

`AppletManager.create` (`Clip/PhotoSearch/Applets/AppletManager.swift`, @MainActor)
persists the applet, then runs the two-step over the existing index with progress,
recording matches **directly** (no notifications for historical photos). Requires a
downloaded VLM + ready CLIP model (else surfaces `AppletManagerError`).

## Notifications

`AppletNotificationManager` over `UNUserNotificationCenter`. Authorization requested
from the app (`requestAuthorizationIfNeeded`) when notifications are enabled;
`notifyCapture` posts an immediate local notification (works from the extension too
once authorized). No prior notification code existed in the app.

## Key files

```
Clip/PhotoSearch/Applets/         Applet, AppletStore, AppletEvaluator,
                                   AppletNotificationManager (+ mocks),
                                   AppletManager
Clip/PhotoSearch/VLM/             VLMModel, VLMModelStore, VLMModelManager,
                                   VLMEngine (+ MockVLMEngine), MLXVLMEngine,
                                   VLMEngineProvider
Clip/PhotoSearch/Ingest/          NewPhotoProcessor, ForegroundPhotoIngestObserver
Clip/ViewControllers/PhotoSearch/Applets/   AppletListViewController,
                                             AppletEditViewController
PouchTests/{Applets,VLM,Ingest}/   AppletStoreTests, VLMModelTests,
                                   AppletEvaluatorTests, NewPhotoProcessorTests
```

## Tests

Swift Testing, in `PouchTests/` (`@testable import clipper`). **`xcodebuild test`
builds and runs; all applet/VLM/ingest tests pass.** Two fixes were needed:
1. App module name pinned to `clipper` (`PRODUCT_MODULE_NAME`) — it had defaulted to
   `Pouch` after the Clipper→Pouch rename, breaking every `@testable import clipper`.
2. The test targets no longer recompile shared `FileFolder.swift` (which had forced
   them to statically link PuttyCore — Xcode 26 rejects a static SPM product linked
   by both app and hosted test target). They get shared types via `@testable import`
   and resolve PuttyCore symbols (MockLogger) from the host app.

Run: `xcodebuild test -scheme Pouch -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:PouchTests`

Known pre-existing failure (NOT applets): `CLIPTextTokenizerTests/
structuralBehaviorWithSyntheticMerges` passes in isolation but fails in the full
run — order-dependent shared state in the tokenizer tests.

## Remaining / follow-ups

- Background reaction to new photos when the app is closed is handled by the pocket
  trigger ([[pocket-trigger]]), not a photo-library background extension.
- Optimization: `MLXVLMEngine` reloads the model per call — cache the container for
  batch/backfill if needed.
- Pre-existing tokenizer test isolation bug (above).
