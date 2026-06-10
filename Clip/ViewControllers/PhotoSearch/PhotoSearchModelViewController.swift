//
//  PhotoSearchModelViewController.swift
//  clipper
//

import Photos
import UIKit

/// Lets the user pick + download an on-device CLIP model and then index (or
/// re-index) their photo library. On successful indexing it loads the index into
/// the shared search service and notifies its owner.
@MainActor
final class PhotoSearchModelViewController: UIViewController {

    /// Called after an index is successfully built and loaded into the service.
    var onIndexReady: (() -> Void)?

    private let context: PhotoSearchContext
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let models = CLIPModel.allCases
    private let vlmModels = VLMModel.allCases

    private var downloadProgress: [CLIPModel: Double] = [:]
    private var vlmDownloadProgress: [VLMModel: Double] = [:]
    private var indexingProgress: Double?
    private var indexingTask: Task<Void, Never>?

    private enum Section: Int, CaseIterable {
        case model
        case vlm
        case index
    }

    init(context: PhotoSearchContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Photo Search Setup"
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(PhotoSearchActionCell.self, forCellReuseIdentifier: PhotoSearchActionCell.reuseID)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private var isIndexing: Bool { indexingProgress != nil }

    private func isBundled(_ model: CLIPModel) -> Bool {
        if case .bundled = model.source { return true }
        return false
    }

    // MARK: - Model download

    private func startDownload(_ model: CLIPModel) {
        guard downloadProgress[model] == nil else { return }
        downloadProgress[model] = 0
        reload(model)

        Task {
            do {
                try await context.modelManager.download(model, onProgress: { value in
                    DispatchQueue.main.async { [weak self] in
                        self?.downloadProgress[model] = value
                        self?.reload(model)
                    }
                })
                downloadProgress[model] = nil
                context.modelStore.selectedModel = model
                tableView.reloadData()
            } catch {
                downloadProgress[model] = nil
                reload(model)
                showAlert(title: "Download failed", message: "Couldn't download the model. Check your connection and try again.")
            }
        }
    }

    private func reload(_ model: CLIPModel) {
        guard let index = models.firstIndex(of: model) else { return }
        tableView.reloadRows(at: [IndexPath(row: index, section: Section.model.rawValue)], with: .none)
    }

    // MARK: - VLM download

    private func startVLMDownload(_ model: VLMModel) {
        guard vlmDownloadProgress[model] == nil else { return }
        vlmDownloadProgress[model] = 0
        reloadVLM(model)

        Task {
            do {
                try await context.vlmModelManager.download(model, onProgress: { value in
                    DispatchQueue.main.async { [weak self] in
                        self?.vlmDownloadProgress[model] = value
                        self?.reloadVLM(model)
                    }
                })
                vlmDownloadProgress[model] = nil
                context.vlmModelStore.selectedModel = model
                tableView.reloadData()
            } catch {
                vlmDownloadProgress[model] = nil
                reloadVLM(model)
                showAlert(title: "Download failed", message: "Couldn't download the language model. Check your connection and try again.")
            }
        }
    }

    private func reloadVLM(_ model: VLMModel) {
        guard let index = vlmModels.firstIndex(of: model) else { return }
        tableView.reloadRows(at: [IndexPath(row: index, section: Section.vlm.rawValue)], with: .none)
    }

    // MARK: - Indexing

    private func beginIndexing(force: Bool) {
        guard !isIndexing else { return }
        let model = context.modelStore.selectedModel
        guard context.modelManager.isDownloaded(model) else {
            showAlert(title: "Download a model first", message: "Choose and download a model before indexing your photos.")
            return
        }

        Task {
            let status = await ensurePhotoAccess()
            guard status == .authorized || status == .limited else {
                showPermissionDeniedAlert()
                return
            }
            runIndexing(model: model, force: force)
        }
    }

    private func runIndexing(model: CLIPModel, force: Bool) {
        indexingProgress = 0
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelIndexing)
        )
        tableView.reloadSections(IndexSet(integer: Section.index.rawValue), with: .none)

        indexingTask = Task {
            do {
                _ = try await context.indexer.reindex(model: model, force: force, onProgress: { value in
                    DispatchQueue.main.async { [weak self] in
                        self?.indexingProgress = value
                        self?.tableView.reloadSections(IndexSet(integer: Section.index.rawValue), with: .none)
                    }
                })
                await context.loadIndexIntoService()
                await MainActor.run {
                    self.finishIndexing()
                    self.onIndexReady?()
                }
            } catch is CancellationError {
                await MainActor.run { self.finishIndexing() }
            } catch {
                await MainActor.run {
                    self.finishIndexing()
                    self.showAlert(title: "Indexing failed", message: "Something went wrong while indexing your photos.")
                }
            }
        }
    }

    @objc private func cancelIndexing() {
        indexingTask?.cancel()
    }

    private func finishIndexing() {
        indexingProgress = nil
        indexingTask = nil
        navigationItem.rightBarButtonItem = nil
        tableView.reloadData()
    }

    // MARK: - Permissions

    private func ensurePhotoAccess() async -> PHAuthorizationStatus {
        let status = context.authorizer.currentStatus
        if status == .notDetermined {
            return await context.authorizer.requestReadAccess()
        }
        return status
    }

    private func showPermissionDeniedAlert() {
        let alert = UIAlertController(
            title: "Photo access needed",
            message: "Photo Search indexes photos on your device. Enable photo access in Settings to continue.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Table data / delegate

extension PhotoSearchModelViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .model: return models.count
        case .vlm: return vlmModels.count
        case .index: return 2
        case .none: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .model: return "Search Model"
        case .vlm: return "Language Model · Applets"
        case .index: return "Photo Index"
        case .none: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .model:
            return "Models run fully on-device and are downloaded on first use."
        case .vlm:
            return "Applets use this model to confirm whether a photo contains what you described. Runs on-device; downloaded on first use."
        case .index:
            return "Indexing analyzes every photo on this device. Run it again any time to pick up new photos, or reprocess all to rebuild from scratch."
        case .none:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dequeued = tableView.dequeueReusableCell(
            withIdentifier: PhotoSearchActionCell.reuseID, for: indexPath
        )
        guard let cell = dequeued as? PhotoSearchActionCell else { return dequeued }

        switch Section(rawValue: indexPath.section) {
        case .model:
            let model = models[indexPath.row]
            let state: PhotoSearchActionCell.State
            if let progress = downloadProgress[model] {
                state = .downloading(progress)
            } else if context.modelManager.isDownloaded(model) {
                state = model == context.modelStore.selectedModel ? .selected : .ready
            } else if isBundled(model) {
                state = .unavailable
            } else {
                state = .needsDownload
            }
            let detail = isBundled(model) && state == .unavailable
                ? "Not included in this build — see conversion script"
                : model.detail
            cell.configure(title: model.displayName, detail: detail, state: state)

        case .vlm:
            let model = vlmModels[indexPath.row]
            let state: PhotoSearchActionCell.State
            if let progress = vlmDownloadProgress[model] {
                state = .downloading(progress)
            } else if context.vlmModelManager.isDownloaded(model) {
                state = model == context.vlmModelStore.selectedModel ? .selected : .ready
            } else {
                state = .needsDownload
            }
            cell.configure(title: model.displayName, detail: model.detail, state: state)

        case .index:
            if indexPath.row == 0 {
                if let progress = indexingProgress {
                    cell.configure(title: "Indexing…", detail: "\(Int(progress * 100))% complete", state: .downloading(progress))
                } else {
                    cell.configure(title: "Process Photo Library", detail: "Index new photos", state: .action(enabled: true))
                }
            } else {
                cell.configure(title: "Reprocess All", detail: "Rebuild the entire index", state: .action(enabled: !isIndexing))
            }
        case .none:
            break
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section) {
        case .model:
            let model = models[indexPath.row]
            guard downloadProgress[model] == nil, !isIndexing else { return }
            if context.modelManager.isDownloaded(model) {
                context.modelStore.selectedModel = model
                tableView.reloadData()
            } else if isBundled(model) {
                showAlert(
                    title: "Model not included",
                    message: "MobileCLIP2 isn't bundled in this build. Generate it with scripts/convert_mobileclip2_coreml.py and add it to the app target."
                )
            } else {
                startDownload(model)
            }
        case .vlm:
            let model = vlmModels[indexPath.row]
            guard vlmDownloadProgress[model] == nil, !isIndexing else { return }
            if context.vlmModelManager.isDownloaded(model) {
                context.vlmModelStore.selectedModel = model
                tableView.reloadData()
            } else {
                startVLMDownload(model)
            }
        case .index:
            guard !isIndexing else { return }
            beginIndexing(force: indexPath.row == 1)
        case .none:
            break
        }
    }
}

// MARK: - Cell

private final class PhotoSearchActionCell: UITableViewCell {

    static let reuseID = "PhotoSearchActionCell"

    enum State: Equatable {
        case ready
        case selected
        case needsDownload
        case unavailable
        case downloading(Double)
        case action(enabled: Bool)
    }

    private let progressView = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, detail: String, state: State) {
        var content = defaultContentConfiguration()
        content.text = title
        content.secondaryText = detail
        accessoryView = nil
        accessoryType = .none
        progressView.isHidden = true
        selectionStyle = .default
        content.textProperties.color = .label

        switch state {
        case .ready:
            break
        case .selected:
            accessoryType = .checkmark
        case .needsDownload:
            let icon = UIImageView(image: UIImage(systemName: "arrow.down.circle"))
            icon.tintColor = .systemBlue
            accessoryView = icon
        case .unavailable:
            content.textProperties.color = .tertiaryLabel
            content.secondaryTextProperties.color = .tertiaryLabel
            selectionStyle = .none
        case .downloading(let progress):
            content.secondaryText = "\(Int(progress * 100))%"
            progressView.isHidden = false
            progressView.progress = Float(progress)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            accessoryView = spinner
            selectionStyle = .none
        case .action(let enabled):
            content.textProperties.color = enabled ? .systemBlue : .tertiaryLabel
            selectionStyle = enabled ? .default : .none
        }

        contentConfiguration = content
    }
}
