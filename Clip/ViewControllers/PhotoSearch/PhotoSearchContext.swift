//
//  PhotoSearchContext.swift
//  clipper
//

import Foundation

/// Shared dependencies + live state for the Photo Search experience, handed to
/// both the model/processing screen and the search grid so they operate on one
/// search service instance.
final class PhotoSearchContext {

    let modelStore: CLIPModelStore
    let modelManager: CLIPModelManager
    let engineProvider: CLIPEngineProvider
    let indexer: PhotoIndexer
    let indexStore: PhotoIndexStore
    let searchService: PhotoSearchService
    let authorizer: PhotoLibraryAuthorizing
    let logger: Logger

    // Applets.
    let vlmModelStore: VLMModelStore
    let vlmModelManager: VLMModelManager
    let vlmEngineProvider: VLMEngineProvider
    let appletStore: AppletStore
    let appletNotificationManager: AppletNotificationManager

    private var cachedEngine: CLIPEmbeddingEngine?
    private var cachedEngineModel: CLIPModel?

    init(
        modelStore: CLIPModelStore,
        modelManager: CLIPModelManager,
        engineProvider: CLIPEngineProvider,
        indexer: PhotoIndexer,
        indexStore: PhotoIndexStore,
        searchService: PhotoSearchService,
        authorizer: PhotoLibraryAuthorizing,
        vlmModelStore: VLMModelStore,
        vlmModelManager: VLMModelManager,
        vlmEngineProvider: VLMEngineProvider,
        appletStore: AppletStore,
        appletNotificationManager: AppletNotificationManager,
        logger: Logger
    ) {
        self.modelStore = modelStore
        self.modelManager = modelManager
        self.engineProvider = engineProvider
        self.indexer = indexer
        self.indexStore = indexStore
        self.searchService = searchService
        self.authorizer = authorizer
        self.vlmModelStore = vlmModelStore
        self.vlmModelManager = vlmModelManager
        self.vlmEngineProvider = vlmEngineProvider
        self.appletStore = appletStore
        self.appletNotificationManager = appletNotificationManager
        self.logger = logger
    }

    /// A VLM engine for the selected model, if it's downloaded. Applets require it.
    func makeVLMEngine() -> VLMEngine? {
        vlmEngineProvider.makeEngine(for: vlmModelStore.selectedModel)
    }

    /// Loads the persisted index into the search service. Returns whether a
    /// usable index for the selected model exists.
    @discardableResult
    func loadIndexIntoService() async -> Bool {
        guard let index = try? indexStore.load() else { return false }
        await searchService.setIndex(index)
        return !index.entries.isEmpty
    }

    /// A text-embedding engine for the selected model, if it's downloaded.
    /// Cached and reused across screen appearances so the Core ML text model
    /// stays loaded and the engine's query-embedding cache stays warm (recreating
    /// it would reload the model and reset the cache, adding latency to search).
    func makeEngine() -> CLIPEmbeddingEngine? {
        let model = modelStore.selectedModel
        if let cachedEngine, cachedEngineModel == model { return cachedEngine }
        let engine = engineProvider.makeEngine(for: model)
        cachedEngine = engine
        cachedEngineModel = model
        return engine
    }
}
