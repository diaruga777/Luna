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
/// by authenticated local installation. A request-only downloader is not
/// sufficient: without the capability there is no proof that the requested
/// generation was installed.
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
                    // The backend itself is fine; this object still needs an
                    // explicit download before it can preview, same as the
                    // no-backend and no-downloader cases below.
                    break
                }
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
            // Keep the request-only protocol source-compatible for callers,
            // but fail closed. A notification that a download was requested
            // is not an authenticated installation result and must never make
            // bytes eligible for preview.
            throw VaultPreviewError.downloadUnavailable
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
        let child: UIViewController
        switch kind {
        case .image: child = VaultImagePreviewViewController(url: url)
        case .pdf: child = VaultPDFPreviewViewController(url: url)
        case .text: child = VaultTextPreviewViewController(url: url)
        case .audio: child = VaultAVPlayerPreviewViewController(url: url)
        case .video: child = VaultAVPlayerPreviewViewController(url: url)
        case .quickLook: child = VaultQuickLookPreviewViewController(url: url)
        }
        guard let lease = try? beginPreview(capability) else {
            return VaultPreviewStatusViewController(plan: VaultPreviewPlan(
                availability: .failed, kind: kind,
                message: "This preview is no longer available."))
        }
        return VaultPreviewLeaseHostingViewController(content: child,
                                                       repository: repository,
                                                       lease: lease,
                                                       capability: capability)
    }

    /// `makeViewController` is the only caller: it begins this lease and
    /// hands it to `VaultPreviewLeaseHostingViewController`, which owns the
    /// whole lease lifecycle from there (renewing while visible, ending on
    /// disappear). A caller of `plan`/`makeViewController` never needs its
    /// own separate lease.
    @discardableResult
    private func beginPreview(_ capability: VaultLocalContentCapability) throws -> VaultPreviewLease {
        guard capability.authenticated,
              try repository.validateLocalContentCapability(capability) else {
            throw VaultPreviewError.unprotectedLocalFile
        }
        let lease = try repository.beginPreviewLease(capability)
        return lease
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

/// Owns the repository lease for the entire presented viewer lifecycle. The
/// lease is renewed while visible and ended as soon as the viewer disappears,
/// allowing iCloud eviction and cache maintenance to proceed safely.
public final class VaultPreviewLeaseHostingViewController: UIViewController {
    private let content: UIViewController
    private let repository: VaultRepository
    private let capability: VaultLocalContentCapability
    private var lease: VaultPreviewLease?
    private var renewalTimer: Timer?

    internal init(content: UIViewController, repository: VaultRepository,
                  lease: VaultPreviewLease,
                  capability: VaultLocalContentCapability) {
        self.content = content
        self.repository = repository
        self.capability = capability
        self.lease = lease
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if lease == nil {
            lease = try? repository.beginPreviewLease(capability)
        }
        renewalTimer?.invalidate()
        renewalTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let lease = self.lease else { return }
            do {
                self.lease = try self.repository.renewPreviewLease(lease,
                                                                     duration: 15 * 60)
            } catch {
                self.renewalTimer?.invalidate()
                self.renewalTimer = nil
            }
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        renewalTimer?.invalidate()
        renewalTimer = nil
        if let lease { try? repository.endPreviewLease(lease) }
        lease = nil
    }

    deinit {
        renewalTimer?.invalidate()
        if let lease { try? repository.endPreviewLease(lease) }
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

/// A centered spinner shown while a preview's file loads off main. Every
/// preview kind that reads its whole file (image, PDF, text) shows this
/// until the load completes, instead of blocking `viewDidLoad`.
@MainActor
private func vaultPreviewSpinner(in view: UIView, color: UIColor? = nil) -> UIActivityIndicatorView {
    let spinner = UIActivityIndicatorView(style: .medium)
    if let color { spinner.color = color }
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimating()
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
        spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    return spinner
}

public final class VaultImagePreviewViewController: UIViewController {
    private let url: URL
    private let imageView = UIImageView()
    public init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)
        let spinner = vaultPreviewSpinner(in: view, color: .white)
        let url = self.url
        Task { [weak self, weak spinner] in
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)
            }.value
            spinner?.removeFromSuperview()
            self?.imageView.image = image
        }
    }
}

public final class VaultPDFPreviewViewController: UIViewController {
    private let url: URL
    private let pdfView = PDFView()
    public init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        pdfView.frame = view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.autoScales = true
        view.addSubview(pdfView)
        let spinner = vaultPreviewSpinner(in: view)
        let url = self.url
        Task { [weak self, weak spinner] in
            let document = await Task.detached(priority: .userInitiated) {
                PDFDocument(url: url)
            }.value
            spinner?.removeFromSuperview()
            self?.pdfView.document = document
        }
    }
}

public final class VaultTextPreviewViewController: UIViewController {
    /// Vault's text preview is for skimming, not a full read. Capping the
    /// load keeps a large plaintext object's preview off main and bounded in
    /// memory instead of reading the whole file.
    private static let maximumPreviewBytes = 262_144
    private let url: URL
    private let textView = UITextView()
    public init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        view.addSubview(textView)
        let spinner = vaultPreviewSpinner(in: view)
        let url = self.url
        Task { [weak self, weak spinner] in
            let text = await Task.detached(priority: .userInitiated) {
                Self.loadBoundedText(at: url)
            }.value
            spinner?.removeFromSuperview()
            self?.textView.text = text
        }
    }

    private static func loadBoundedText(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumPreviewBytes) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if data.count == maximumPreviewBytes { text += "\n\n[Preview truncated]" }
        return text
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
