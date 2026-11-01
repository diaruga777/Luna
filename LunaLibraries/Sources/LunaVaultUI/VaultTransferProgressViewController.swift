import UIKit
import LunaVaultBEP

/// A short preparation spinner becomes determinate progress after one second,
/// including 0 bytes while the peer is still preparing its first response.
public final class VaultTransferProgressViewController: UIViewController {
    public let spinner = UIActivityIndicatorView(style: .large)
    public let progressView = UIProgressView(progressViewStyle: .default)
    public let byteLabel = UILabel()
    public let statusLabel = UILabel()
    private let filename: String
    private let transferring: Bool
    private let clock: () -> Date
    private let started: Date
    private var lastAdvance: Date
    private var snapshot: VaultTransferProgress?
    private var timer: Task<Void, Never>?
    public var onCancel: (() -> Void)?

    public init(filename: String, transferring: Bool = true, clock: @escaping () -> Date = { Date() }) {
        self.filename = filename; self.transferring = transferring
        self.clock = clock; started = clock(); lastAdvance = started
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.cancel() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = transferring ? "Transferring" : "Queuing"
        view.backgroundColor = .systemBackground
        let name = UILabel()
        name.text = filename; name.font = .preferredFont(forTextStyle: .headline)
        for label in [name, statusLabel, byteLabel] {
            label.numberOfLines = 0; label.textAlignment = .center; label.adjustsFontForContentSizeCategory = true
        }
        name.numberOfLines = 3; name.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        byteLabel.font = .preferredFont(forTextStyle: .subheadline)
        byteLabel.textColor = .secondaryLabel
        byteLabel.accessibilityIdentifier = "vault.transfer.bytes"
        progressView.accessibilityIdentifier = "vault.transfer.progress"
        let stack = UIStackView(arrangedSubviews: [name, spinner, statusLabel, progressView, byteLabel])
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in self?.onCancel?() })
        spinner.startAnimating()
        render()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                render()
            }
        }
    }
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.cancel(); timer = nil
    }
    public func update(_ progress: VaultTransferProgress) {
        if snapshot == nil || progress.completedBytes != snapshot?.completedBytes { lastAdvance = clock() }
        snapshot = progress
        if isViewLoaded { render() }
    }
    private func render() {
        let determinate = transferring && clock().timeIntervalSince(started) >= 1
        spinner.isHidden = determinate
        if determinate { spinner.stopAnimating() }
        progressView.isHidden = !determinate; byteLabel.isHidden = !determinate
        progressView.progress = Float(snapshot?.fractionCompleted ?? 0)
        let completed = ByteCountFormatter.string(fromByteCount: snapshot?.completedBytes ?? 0, countStyle: .file)
        byteLabel.text = snapshot.map { "\(completed) of \(ByteCountFormatter.string(fromByteCount: $0.totalBytes, countStyle: .file))" } ?? "\(completed) transferred"
        if !transferring { statusLabel.text = "Preparing files for sync to your Mac." }
        else if let snapshot, snapshot.completedBytes == snapshot.totalBytes { statusLabel.text = "Finishing transfer…" }
        else if clock().timeIntervalSince(lastAdvance) >= 15 { statusLabel.text = "Waiting for your Mac…" }
        else { statusLabel.text = "Transferring from your Mac…" }
    }
}
