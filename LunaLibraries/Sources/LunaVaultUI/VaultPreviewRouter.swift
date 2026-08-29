import AVFoundation
import AVKit
import Foundation
import UniformTypeIdentifiers
import PDFKit
import QuickLook
import UIKit
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultSetup
import LunaVaultStorage

public enum VaultPreviewKind: String, Sendable {
    case image
    case pdf
    case text
    case audio
    case video
    case quickLook
}

public enum VaultPreviewAvailability: Equatable, Sendable {
    case ready
    case needsDownload
    case downloading
    case unavailable
    case failed
}

public struct VaultPreviewPlan: Equatable, Sendable {
    public let availability: VaultPreviewAvailability
    public let kind: VaultPreviewKind?
    /// Only returned for local protected bytes. Remote ciphertext and remote
    /// URLs are never represented by this plan.
    public let localURL: URL?
    /// Repository-issued proof for `localURL`; callers should retain this
    /// capability while presenting a preview and release it afterward.
    public let capability: VaultLocalContentCapability?
    public let message: String?

    internal init(availability: VaultPreviewAvailability, kind: VaultPreviewKind? = nil,
                  localURL: URL? = nil, capability: VaultLocalContentCapability? = nil,
                  message: String? = nil) {
        self.availability = availability
        self.kind = kind
        self.localURL = localURL
        self.capability = capability
        self.message = message
    }
}

public protocol VaultPreviewDownloadRequesting: Sendable {
    func requestDownload(for identity: VaultRemoteObjectIdentity) async throws
}

/// Strict preview downloads return the repository-issued capability produced
/// by authenticated local installation. The request-only protocol remains
/// source-compatible for older app compositions, but cannot attest a generation.
public protocol VaultPreviewDownloadResultProviding: VaultPreviewDownloadRequesting {
    func requestDownloadResult(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultLocalContentCapability
}

public enum VaultPreviewError: Error, Equatable, Sendable {
    case missingObject
    case tombstoned
    case unprotectedLocalFile
    case unsupported
    case downloadUnavailable
}

/// Routes only to local, Data-Protected bytes. A remote identity can be
/// supplied to report a download-needed state, but is never converted into a
/// URL. Callers explicitly request a complete authenticated download before
/// video playback; encrypted-range streaming is intentionally unsupported.
public final class VaultPreviewRouter: @unchecked Sendable {
    private let repository: VaultRepository
    private let cache: VaultCacheCoordinator?
    private let protection: VaultFileProtectionApplying
    private let backend: VaultBackendTransport?
    private let downloadRequester: VaultPreviewDownloadRequesting?
    private let metadataStore: VaultImportedFileMetadataStoring?

    public init(repository: VaultRepository, cache: VaultCacheCoordinator? = nil,
                backend: VaultBackendTransport? = nil,
                downloadRequester: VaultPreviewDownloadRequesting? = nil,
                metadataStore: VaultImportedFileMetadataStoring? = nil,
                protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier()) {
        self.repository = repository
        self.cache = cache
        self.backend = backend
        self.downloadRequester = downloadRequester
        self.metadataStore = metadataStore
        self.protection = protectionApplier
    }

    public func plan(objectID: VaultObjectID,
                     remoteIdentity: VaultRemoteObjectIdentity? = nil) async throws -> VaultPreviewPlan {
        guard let record = try repository.object(objectID) else { throw VaultPreviewError.missingObject }
        guard !record.isTombstone else { throw VaultPreviewError.tombstoned }
        if let capability = try repository.localContentCapability(for: objectID), capability.authenticated,
           remoteIdentity == nil || (remoteIdentity?.revision == capability.revision &&
                                     remoteIdentity?.generation == capability.generation) {
            let url = capability.localURL
            let fileName = (try? metadataStore?.metadata(objectID: objectID,
                                                         revision: record.revision)?.fileName) ?? ""
            let kind = kind(for: record.contentType, fileName: fileName)
            try? cache?.markAccessed(objectID, byteCount: record.size, fullContent: true, now: Date())
            return VaultPreviewPlan(availability: .ready, kind: kind, localURL: url,
                                    capability: capability)
        }

        let url = repository.contentDirectory
            .appendingPathComponent(objectID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent("content")
        if FileManager.default.fileExists(atPath: url.path) {
            // A path exists but failed repository authentication. Do not hand
            // it to AVKit/QuickLook; the caller must repair or re-download it.
            guard try protection.hasRequiredProtection(at: url) else {
                throw VaultPreviewError.unprotectedLocalFile
            }
        }

        if let remoteIdentity {
            if let backend {
                switch backend.currentAvailability {
                case .downloading: return VaultPreviewPlan(availability: .downloading, message: "Downloading from Vault…")
                case .needsDownload: return VaultPreviewPlan(availability: .needsDownload, message: "Download this file to preview it.")
                case .unavailable: return VaultPreviewPlan(availability: .unavailable, message: "Vault storage is unavailable.")
                case .failed: return VaultPreviewPlan(availability: .failed, message: "Vault storage reported an error.")
                case .available, .evicting:
                    _ = remoteIdentity
                }
            }
            if downloadRequester == nil {
                return VaultPreviewPlan(availability: .needsDownload, message: "Download this file to preview it.")
            }
            return VaultPreviewPlan(availability: .needsDownload, message: "Download this file to preview it.")
        }
        return VaultPreviewPlan(availability: .unavailable, message: "This file is not downloaded on this device.")
    }

    /// Requests a complete authenticated download. The requester is injected
    /// by the app's sync composition; this method cannot expose ciphertext or
    /// create a partial/range playback URL.
    public func downloadAndPlan(objectID: VaultObjectID,
                                identity: VaultRemoteObjectIdentity) async throws -> VaultPreviewPlan {
        guard identity.objectID == objectID,
              let record = try repository.object(objectID),
              !record.isTombstone, record.revision == identity.revision,
              identity.kind == .content,
              identity.generation.count == 64,
              identity.generation.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw VaultPreviewError.unsupported
        }
        guard let downloadRequester else { throw VaultPreviewError.downloadUnavailable }
        if let resultProvider = downloadRequester as? VaultPreviewDownloadResultProviding {
            let capability = try await resultProvider.requestDownloadResult(for: identity)
            guard capability.authenticated,
                  capability.objectID == objectID,
                  capability.revision == identity.revision,
                  capability.generation == identity.generation,
                  capability.byteCount == record.size,
                  try repository.validateLocalContentCapability(capability) else {
                throw VaultPreviewError.downloadUnavailable
            }
        } else {
            try await downloadRequester.requestDownload(for: identity)
        }
        return try await plan(objectID: objectID, remoteIdentity: identity)
    }

    public func makeViewController(for plan: VaultPreviewPlan) -> UIViewController {
        guard plan.availability == .ready, let url = plan.localURL,
              let capability = plan.capability, capability.authenticated,
              capability.localURL == url,
              (try? repository.validateLocalContentCapability(capability)) == true,
              let kind = plan.kind else {
            return VaultPreviewStatusViewController(plan: plan)
        }
        switch kind {
        case .image: return VaultImagePreviewViewController(url: url)
        case .pdf: return VaultPDFPreviewViewController(url: url)
        case .text: return VaultTextPreviewViewController(url: url)
        case .audio: return VaultAVPlayerPreviewViewController(url: url)
        case .video: return VaultAVPlayerPreviewViewController(url: url)
        case .quickLook: return VaultQuickLookPreviewViewController(url: url)
        }
    }

    public func beginPreview(_ capability: VaultLocalContentCapability) throws {
        guard capability.authenticated,
              try repository.validateLocalContentCapability(capability) else {
            throw VaultPreviewError.unprotectedLocalFile
        }
        try repository.setPreviewActive(capability.objectID, active: true)
        try repository.setPinned(capability.objectID, pinned: true)
    }

    public func endPreview(_ capability: VaultLocalContentCapability) throws {
        try repository.setPreviewActive(capability.objectID, active: false)
        try repository.setPinned(capability.objectID, pinned: false)
    }

    private func kind(for contentType: String?, fileName: String) -> VaultPreviewKind {
        let lower = fileName.lowercased()
        let ext = URL(fileURLWithPath: lower).pathExtension
        let normalizedType = contentType?.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let type = normalizedType.flatMap { UTType($0) ?? UTType(mimeType: $0) }
            ?? UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true || ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext) {
            return .image
        }
        if type?.conforms(to: .pdf) == true || ext == "pdf" { return .pdf }
        if type?.conforms(to: .text) == true || ["txt", "md", "markdown", "json", "csv", "html"].contains(ext) {
            return .text
        }
        if type?.conforms(to: .audio) == true { return .audio }
        if type?.conforms(to: .movie) == true { return .video }
        return .quickLook
    }

}

public final class VaultPreviewStatusViewController: UIViewController {
    private let plan: VaultPreviewPlan
    private let label = UILabel()

    public init(plan: VaultPreviewPlan) {
        self.plan = plan
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.text = plan.message ?? "Preview unavailable."
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

public final class VaultImagePreviewViewController: UIViewController {
    private let url: URL
    public init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let imageView = UIImageView(frame: view.bounds)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(contentsOfFile: url.path)
        view.addSubview(imageView)
    }
}

public final class VaultPDFPreviewViewController: UIViewController {
    private let url: URL
    public init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let pdf = PDFView(frame: view.bounds)
        pdf.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdf.autoScales = true
        pdf.document = PDFDocument(url: url)
        view.addSubview(pdf)
    }
}

public final class VaultTextPreviewViewController: UIViewController {
    private let url: URL
    public init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let textView = UITextView(frame: view.bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.text = try? String(contentsOf: url, encoding: .utf8)
        view.addSubview(textView)
    }
}

/// Media playback receives a local protected URL only after full download and
/// decryption. No AVAssetResourceLoader or encrypted-range path is installed.
public final class VaultAVPlayerPreviewViewController: UIViewController {
    private let url: URL
    private var player: AVPlayer?
    public init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let controller = AVPlayerViewController()
        player = AVPlayer(url: url)
        controller.player = player
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
    }
}

public final class VaultQuickLookPreviewViewController: QLPreviewController, QLPreviewControllerDataSource {
    private let itemURL: URL
    public init(url: URL) {
        itemURL = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { itemURL as NSURL }
}
