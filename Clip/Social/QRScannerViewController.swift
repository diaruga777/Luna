//
//  QRScannerViewController.swift
//  Clip
//

import AVFoundation
import UIKit

/// Full-screen camera QR scanner for friend codes. Recognizes the same
/// `clipreader://friend` URLs as tapped links and hands the parsed card to
/// its completion (the presenter runs the confirm-add flow).
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    private let onCard: (IdentityCard) -> Void
    private let session = AVCaptureSession()
    private var hasDelivered = false

    init(onCard: @escaping (IdentityCard) -> Void) {
        self.onCard = onCard
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let closeButton = UIButton(type: .system)
        let closeImage = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 32))
        closeButton.setImage(closeImage, for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let hintLabel = UILabel()
        hintLabel.text = "Point at a friend's Clip code"
        hintLabel.textColor = .white
        hintLabel.font = .preferredFont(forTextStyle: .headline)
        hintLabel.textAlignment = .center

        configureCaptureSession()

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func configureCaptureSession() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input)
        else {
            // No camera (simulator): leave the black screen with the close button.
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDelivered,
              let qr = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let text = qr.stringValue,
              let url = URL(string: text),
              let card = FriendLink.card(from: url)
        else { return }
        hasDelivered = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true) { [onCard] in
            onCard(card)
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
