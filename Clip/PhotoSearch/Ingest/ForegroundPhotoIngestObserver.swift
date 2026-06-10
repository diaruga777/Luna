//
//  ForegroundPhotoIngestObserver.swift
//  clipper
//

import Foundation
import Photos

/// Watches the photo library while the app is active and runs the applet ingest
/// pipeline on newly added photos — the in-app counterpart to the background ingest
/// extension. `PHPhotoLibraryChangeObserver` only fires while the process is alive,
/// so this covers "process immediately while the app is open" (and catches
/// iCloud-optimized assets the extension skips). It no-ops unless a CLIP model and
/// a VLM are both ready and at least one applet exists.
final class ForegroundPhotoIngestObserver: NSObject, PHPhotoLibraryChangeObserver {

    private let context: PhotoSearchContext
    private var fetchResult: PHFetchResult<PHAsset>?
    private var registered = false

    init(context: PhotoSearchContext) {
        self.context = context
    }

    /// Establishes the baseline asset set and begins observing.
    func start() {
        guard !registered else { return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchResult = PHAsset.fetchAssets(with: options)
        PHPhotoLibrary.shared().register(self)
        registered = true
    }

    func stop() {
        guard registered else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        registered = false
    }

    deinit {
        if registered { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    // MARK: - PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let current = fetchResult,
              let details = changeInstance.changeDetails(for: current) else { return }
        fetchResult = details.fetchResultAfterChanges
        let inserted = details.insertedObjects
        guard !inserted.isEmpty else { return }

        let newAssets = inserted.map {
            (id: $0.localIdentifier, date: $0.creationDate ?? Date())
        }
        Task { await self.process(newAssets) }
    }

    private func process(_ assets: [(id: String, date: Date)]) async {
        let applets = (try? context.appletStore.list()) ?? []
        guard !applets.isEmpty, let processor = makeProcessor() else { return }
        for asset in assets {
            _ = await processor.process(assetIdentifier: asset.id, creationDate: asset.date)
        }
    }

    /// Builds the ingest pipeline for the selected CLIP + VLM models. Returns nil if
    /// either isn't ready (applets can't run without embeddings + the VLM). Built
    /// directly from the providers to avoid touching the context's main-actor engine
    /// cache off the main thread.
    private func makeProcessor() -> NewPhotoProcessor? {
        let clipModel = context.modelStore.selectedModel
        guard let clipEngine = context.engineProvider.makeEngine(for: clipModel),
              let vlmEngine = context.vlmEngineProvider.makeEngine(for: context.vlmModelStore.selectedModel) else {
            return nil
        }
        let analyzer = CLIPFrameAnalyzer(
            engine: clipEngine,
            textRecognizer: VisionImageTextRecognizer(),
            logger: context.logger
        )
        let evaluator = AppletEvaluatorImpl(
            store: context.appletStore,
            clipEngine: clipEngine,
            vlmEngine: vlmEngine,
            notifier: context.appletNotificationManager,
            clipModelIdentifier: clipModel.rawValue,
            logger: context.logger
        )
        return NewPhotoProcessorImpl(
            assetSource: PhotoKitAssetSource(),
            analyzer: analyzer,
            indexStore: context.indexStore,
            evaluator: evaluator,
            modelIdentifier: clipModel.rawValue,
            imageInputSize: clipModel.imageInputSize,
            logger: context.logger
        )
    }
}
