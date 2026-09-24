import AVFoundation
import ImageIO
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import LunaVaultStore

/// A file exported from the user's photo library. `destinationURL` is durable and
/// can be handed to the Vault import/sync queue immediately.
public struct VaultPhotoExportedFile: Sendable {
    public let assetIdentifier: String
    public let stagedURL: URL
    public let relativeName: String
    public let isDirectory: Bool

    public init(assetIdentifier: String, stagedURL: URL, relativeName: String, isDirectory: Bool = false) {
        self.assetIdentifier = assetIdentifier
        self.stagedURL = stagedURL
        self.relativeName = relativeName
        self.isDirectory = isDirectory
    }

    public var destinationURL: URL { stagedURL }
}

public enum VaultPhotoSelectionError: LocalizedError {
    case accessDenied
    case noAssetIdentifier
    case assetUnavailable(String)
    case exportFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .accessDenied: return "Photos access is required to select photos and videos."
        case .noAssetIdentifier: return "The selected photo could not be identified."
        case .assetUnavailable(let id): return "The selected photo is no longer available (\(id))."
        case .exportFailed(let reason): return "The selected photo could not be exported: \(reason)"
        case .cancelled: return "Photo selection was cancelled."
        }
    }
}

/// Presents PhotoKit pickers and stages exports on disk for the import queue.
@MainActor
public final class VaultPhotoSelectionCoordinator: NSObject, PHPickerViewControllerDelegate {
    public typealias Completion = (Result<[VaultPhotoExportedFile], Error>) -> Void
    public var onExportStart: (() -> Void)?
    public var imageFormat: VaultPhotoImageFormat = .jpeg
    public var videoFormat: VaultPhotoVideoFormat = .mp4

    private var pickerRequest: (destinationRootURL: URL, albumName: String?, completion: Completion)?

    public override init() {}

    /// Presents the system picker for one or more individual photos/videos.
    /// `destinationRootURL` should be a durable staging directory in the Vault
    /// container. Files are written beneath it, optionally under `albumName`.
    public func presentItemPicker(from presenter: UIViewController,
                                  destinationRootURL: URL,
                                  albumName: String? = nil,
                                  completion: @escaping Completion) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current

        pickerRequest = (destinationRootURL, albumName, completion)
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    /// Presents a small album chooser. Choosing an album exports every image
    /// and video currently visible to the app in that album.
    public func presentAlbumPicker(from presenter: UIViewController,
                                   destinationRootURL: URL,
                                   completion: @escaping Completion) {
        requestPhotoAccess { [weak self, weak presenter] granted in
            guard let self, let presenter else { return }
            guard granted else { completion(.failure(VaultPhotoSelectionError.accessDenied)); return }
            let albums = self.fetchAlbums()
            guard !albums.isEmpty else {
                completion(.failure(VaultPhotoSelectionError.exportFailed("No photo albums are available.")))
                return
            }
            let alert = UIAlertController(title: "Choose an Album", message: nil, preferredStyle: .actionSheet)
            for album in albums {
                alert.addAction(UIAlertAction(title: album.localizedTitle ?? "Untitled Album", style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.onExportStart?()
                    self.exportAlbum(album, to: destinationRootURL, completion: completion)
                })
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                completion(.failure(VaultPhotoSelectionError.cancelled))
            })
            if let popover = alert.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                                            width: 1, height: 1)
            }
            presenter.present(alert, animated: true)
        }
    }

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let request = pickerRequest else { return }
        pickerRequest = nil
        guard !results.isEmpty else {
            request.completion(.failure(VaultPhotoSelectionError.cancelled))
            return
        }
        onExportStart?()
        exportProviders(results.map { ($0, $0.assetIdentifier) }, to: request.destinationRootURL,
                        albumName: request.albumName, completion: request.completion)
    }

    private func exportProviders(_ providers: [(PHPickerResult, String?)], to root: URL,
                                 albumName: String?, completion: @escaping Completion) {
        let photosFolder = root.appendingPathComponent("Photos", isDirectory: true)
        let folder = albumName.map { photosFolder.appendingPathComponent(safeComponent($0), isDirectory: true) } ?? photosFolder
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { completion(.failure(error)); return }
        var output: [VaultPhotoExportedFile] = []
        func next(_ index: Int) {
            guard index < providers.count else { completion(.success(output)); return }
            let (result, selectedIdentifier) = providers[index]
            let identifier = selectedIdentifier ?? UUID().uuidString
            let type = result.itemProvider.registeredTypeIdentifiers.first {
                guard let value = UTType($0) else { return false }
                return value.conforms(to: .image) || value.conforms(to: .movie)
            } ?? UTType.item.identifier
            let suggestedName = result.itemProvider.suggestedName
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] temporaryURL, error in
                // Item-provider temporary files exist only inside this callback.
                let copied: Result<URL, Error> = Result {
                    if let error { throw error }
                    guard let temporaryURL else { throw VaultPhotoSelectionError.exportFailed("No file was returned.") }
                    let original = (suggestedName ?? temporaryURL.lastPathComponent)
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "\\", with: "_")
                    let ext = (original as NSString).pathExtension.isEmpty
                        ? (UTType(type)?.preferredFilenameExtension ?? temporaryURL.pathExtension) : ""
                    let filename = ext.isEmpty ? original : original + "." + ext
                    let destination = folder.appendingPathComponent(UUID().uuidString + "-" + filename)
                    try FileManager.default.copyItem(at: temporaryURL, to: destination)
                    return destination
                }
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        let destination = try copied.get()
                        let original = String(destination.lastPathComponent.dropFirst(37))
                        let mediaType = UTType(filenameExtension: destination.pathExtension) ?? UTType(type)
                        let (staged, exportedName) = try await self.convertIfNeeded(destination, named: original,
                            mediaType: mediaType, in: folder)
                        let name = self.uniqueFilename(original: exportedName, in: folder)
                        let normalized = folder.appendingPathComponent(name)
                        try FileManager.default.moveItem(at: staged, to: normalized)
                        output.append(VaultPhotoExportedFile(assetIdentifier: identifier,
                                                             stagedURL: normalized,
                                                             relativeName: ["Photos", albumName.map(self.safeComponent), name].compactMap { $0 }.joined(separator: "/")))
                        next(index + 1)
                    } catch { completion(.failure(error)) }
                }
            }
        }
        next(0)
    }

    private func exportAlbum(_ album: PHAssetCollection, to root: URL, completion: @escaping Completion) {
        let assets = PHAsset.fetchAssets(in: album, options: {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            return options
        }())
        var identifiers: [String] = []
        assets.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
        let albumName = album.localizedTitle ?? "Photos"
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
            .appendingPathComponent(safeComponent(albumName), isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { completion(.failure(error)); return }
        var output: [VaultPhotoExportedFile] = []
        func next(_ index: Int) {
            guard index < identifiers.count else {
                if output.isEmpty {
                    output.append(VaultPhotoExportedFile(assetIdentifier: album.localIdentifier,
                        stagedURL: folder, relativeName: "Photos/" + self.safeComponent(albumName), isDirectory: true))
                }
                completion(.success(output))
                return
            }
            let id = identifiers[index]
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                completion(.failure(VaultPhotoSelectionError.assetUnavailable(id))); return
            }
            do {
                let resource = try self.originalResource(for: asset)
                let resourceTypeIdentifier = resource.uniformTypeIdentifier
                let destination = folder.appendingPathComponent(self.uniqueFilename(original: resource.originalFilename, in: folder))
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error { completion(.failure(error)); return }
                        do {
                            let mediaType = UTType(resourceTypeIdentifier) ?? UTType(filenameExtension: destination.pathExtension)
                            let (staged, exportedName) = try await self.convertIfNeeded(destination,
                                named: destination.lastPathComponent, mediaType: mediaType, in: folder)
                            let name = staged == destination ? destination.lastPathComponent
                                : self.uniqueFilename(original: exportedName, in: folder)
                            let finalURL = folder.appendingPathComponent(name)
                            if staged != finalURL { try FileManager.default.moveItem(at: staged, to: finalURL) }
                            output.append(VaultPhotoExportedFile(assetIdentifier: id, stagedURL: finalURL,
                                relativeName: ["Photos", self.safeComponent(albumName), name].joined(separator: "/")))
                            next(index + 1)
                        } catch { completion(.failure(error)) }
                    }
                }
            } catch { completion(.failure(error)) }
        }
        next(0)
    }

    private func originalResource(for asset: PHAsset) throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }) {
            return resource
        }
        if let resource = resources.first(where: { $0.type == .photo || $0.type == .video }) { return resource }
        throw VaultPhotoSelectionError.assetUnavailable(asset.localIdentifier)
    }

    func convertIfNeeded(_ source: URL, named name: String, mediaType: UTType?, in folder: URL)
        async throws -> (URL, String) {
        let isVideo = mediaType?.conforms(to: .movie) == true || mediaType?.conforms(to: .video) == true
        let isImage = mediaType?.conforms(to: .image) == true
        if isVideo && videoFormat == .mp4 && source.pathExtension.lowercased() != "mp4" {
            let target = folder.appendingPathComponent(".convert-\(UUID().uuidString).mp4")
            do {
                let asset = AVURLAsset(url: source)
                guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                    throw VaultPhotoSelectionError.exportFailed("This video cannot be converted to MP4.")
                }
                try await exporter.export(to: target, as: .mp4)
                try FileManager.default.removeItem(at: source)
                return (target, (name as NSString).deletingPathExtension + ".mp4")
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }
        if isImage && imageFormat == .jpeg && !["jpg", "jpeg"].contains(source.pathExtension.lowercased()) {
            let target = folder.appendingPathComponent(".convert-\(UUID().uuidString).jpg")
            do {
                try await Task.detached(priority: .userInitiated) {
                    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
                          let destination = CGImageDestinationCreateWithURL(target as CFURL,
                              UTType.jpeg.identifier as CFString, 1, nil) else {
                        throw VaultPhotoSelectionError.exportFailed("This image cannot be converted to JPEG.")
                    }
                    CGImageDestinationAddImageFromSource(destination, image, 0,
                        [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else {
                        throw VaultPhotoSelectionError.exportFailed("This image cannot be converted to JPEG.")
                    }
                }.value
                try FileManager.default.removeItem(at: source)
                return (target, (name as NSString).deletingPathExtension + ".jpg")
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }
        return (source, name)
    }

    private func requestPhotoAccess(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { completion(true); return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in completion(status == .authorized || status == .limited) }
        }
    }

    private func fetchAlbums() -> [PHAssetCollection] {
        var albums: [PHAssetCollection] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            albums.append(collection)
        }
        return albums.sorted { ($0.localizedTitle ?? "") < ($1.localizedTitle ?? "") }
    }

    private func safeComponent(_ component: String) -> String {
        let cleaned = component.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Photos" : cleaned
    }

    private func uniqueFilename(original: String, in directory: URL) -> String {
        let base = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: original).pathExtension
        let extensionSuffix = ext.isEmpty ? "" : "." + ext
        var candidate = original.isEmpty ? "Photo" + extensionSuffix : original
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(index))" + extensionSuffix
            index += 1
        }
        return candidate
    }
}
