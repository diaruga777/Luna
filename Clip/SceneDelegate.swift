//
//  SceneDelegate.swift
//  Clip
//
//  Clip is the on-device photo-search + applets experience: no login, no camera.
//  The whole app is the photo-search root.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PhotoSearchRootViewController(context: Self.makeContext())
        self.window = window
        window.makeKeyAndVisible()
    }

    /// Builds the photo-search dependency graph (CLIP + photo index + VLM + applets).
    /// Everything runs on-device; photos never leave the phone.
    private static func makeContext() -> PhotoSearchContext {
        let logger = Logger()

        let clipModelManager = CLIPModelManagerImpl(logger: logger)
        let clipEngineProvider = CLIPEngineProviderImpl(
            modelManager: clipModelManager,
            makeTokenizer: {
                if let bundled = BPECLIPTokenizer.bundled() { return bundled }
                logger.error("clip_merges data set missing; CLIP text search will be degraded")
                return BPECLIPTokenizer(mergesFileContents: "")
            },
            logger: logger
        )
        let photoIndexStore = PhotoIndexStoreImpl(logger: logger)
        let analyzerProvider = PhotoFrameAnalyzerProviderImpl(
            engineProvider: clipEngineProvider,
            textRecognizer: VisionImageTextRecognizer(),
            logger: logger
        )
        let photoIndexer = PhotoIndexerImpl(
            assetSource: PhotoKitAssetSource(),
            analyzerProvider: analyzerProvider,
            indexStore: photoIndexStore,
            logger: logger
        )
        let vlmModelManager = VLMModelManagerImpl(logger: logger)

        return PhotoSearchContext(
            modelStore: CLIPModelStoreImpl(),
            modelManager: clipModelManager,
            engineProvider: clipEngineProvider,
            indexer: photoIndexer,
            indexStore: photoIndexStore,
            searchService: PhotoSearchServiceImpl(),
            authorizer: PhotoLibraryAuthorizer(),
            vlmModelStore: VLMModelStoreImpl(),
            vlmModelManager: vlmModelManager,
            vlmEngineProvider: VLMEngineProviderImpl(modelManager: vlmModelManager, logger: logger),
            appletStore: AppletStoreImpl(logger: logger),
            appletNotificationManager: AppletNotificationManagerImpl(),
            logger: logger
        )
    }
}
