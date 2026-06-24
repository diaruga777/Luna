//
//  ImageLightboxViewController.swift
//  Clip
//

import UIKit

/// A frameless, zoomable image viewer. It starts at the inline attachment's frame
/// and returns there on dismissal, preserving the reader's spatial context.
final class ImageLightboxViewController: UIViewController, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    private let image: UIImage
    private let sourceFrame: CGRect
    private let dimmingView = UIView()
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private var restingFrame = CGRect.zero

    init(image: UIImage, sourceFrame: CGRect) {
        self.image = image
        self.sourceFrame = sourceFrame
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        dimmingView.alpha = 0
        dimmingView.frame = view.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimmingView)

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = false
        scrollView.frame = sourceFrame
        view.addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        imageView.addInteraction(UIContextMenuInteraction(delegate: self))

        closeButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark", padding: 12)
        closeButton.alpha = 0
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(outsideTapped(_:)))
        outsideTap.delegate = self
        view.addGestureRecognizer(outsideTap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restingFrame = fittedFrame(in: view.bounds.inset(by: UIEdgeInsets(top: 56, left: 16, bottom: 40, right: 16)))
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
            self.dimmingView.alpha = 1
            self.scrollView.frame = self.restingFrame
            self.imageView.frame = self.scrollView.bounds
            self.closeButton.frame = CGRect(x: self.restingFrame.minX - 6, y: self.restingFrame.minY - 46, width: 44, height: 44)
            self.closeButton.alpha = 1
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func closeTapped() { dismissToSource() }

    @objc private func outsideTapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: view)
        guard !scrollView.frame.contains(point), !closeButton.frame.contains(point) else { return }
        dismissToSource()
    }

    private func dismissToSource() {
        scrollView.setZoomScale(1, animated: false)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn]) {
            self.dimmingView.alpha = 0
            self.closeButton.alpha = 0
            self.scrollView.frame = self.sourceFrame
            self.imageView.frame = self.scrollView.bounds
        } completion: { _ in
            self.dismiss(animated: false)
        }
    }

    private func fittedFrame(in bounds: CGRect) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.image = self.image
                },
                UIAction(title: "Save Image", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    UIImageWriteToSavedPhotosAlbum(self.image, nil, nil, nil)
                },
            ])
        }
    }
}

extension ImageLightboxViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view !== closeButton
    }
}
