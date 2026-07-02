//
//  ImageLightboxViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaTransitions
import UIKit

/// A frameless, zoomable image viewer. It starts at the inline attachment's frame
/// and returns there on dismissal, preserving the reader's spatial context.
public final class ImageLightboxViewController: UIViewController, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    private let image: UIImage
    private let sourceFrame: CGRect
    private let dimmingView = UIView()
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private var restingFrame = CGRect.zero
    /// Drag-to-dismiss, only while zoomed all the way out: a far-enough or fast-enough
    /// swipe flings the image away and dismisses; a short drag springs back.
    private let dismissPan = UIPanGestureRecognizer()
    private var isDismissing = false

    public init(image: UIImage, sourceFrame: CGRect) {
        self.image = image
        self.sourceFrame = sourceFrame
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
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
        // At min zoom the content exactly fits, so the scroll view never bounces or
        // scrolls — leaving the drag free for our dismiss gesture (which recognizes
        // simultaneously with the scroll view's own pan, gated to min zoom).
        scrollView.bounces = false
        scrollView.frame = sourceFrame
        view.addSubview(scrollView)

        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        scrollView.addGestureRecognizer(dismissPan)

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

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restingFrame = fittedFrame(in: view.bounds.inset(by: UIEdgeInsets(top: 56, left: 16, bottom: 40, right: 16)))
        let applyOpenState = {
            self.dimmingView.alpha = 1
            self.scrollView.frame = self.restingFrame
            self.imageView.frame = self.scrollView.bounds
            self.closeButton.frame = CGRect(x: self.restingFrame.minX - 6, y: self.restingFrame.minY - 46, width: 44, height: 44)
            self.closeButton.alpha = 1
        }
        // Dot Matrix open (appear-in-place): the image's FINAL frame materialises as
        // random dots that sharpen, while the dimming and close button just fade via
        // the chrome layer. Captured from the window, so the "before" is the real
        // reader (the presentation is committed and still pixel-identical to it).
        if DotMatrixTransitionCenter.shared.isEnabled, let window = view.window {
            let region = view.convert(restingFrame, to: window).integral
            DotMatrixCrossfade.run(in: window, direction: .random, region: region,
                                   chromeFade: true, changes: {
                applyOpenState()
                window.layoutIfNeeded()
            })
            return
        }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut], animations: applyOpenState)
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func closeTapped() { dismissToSource() }

    @objc private func outsideTapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: view)
        guard !scrollView.frame.contains(point), !closeButton.frame.contains(point) else { return }
        dismissToSource()
    }

    private func dismissToSource() {
        scrollView.setZoomScale(1, animated: false)
        let applyClosedState = {
            self.dimmingView.alpha = 0
            self.closeButton.alpha = 0
            self.scrollView.frame = self.sourceFrame
            self.imageView.frame = self.scrollView.bounds
        }
        // Dot Matrix close — the open's mirror: the image dissolves back into the
        // reader content behind it (its frame is the wipe region) while the dimming
        // fades out. The "after" restores the image copy onto its inline source
        // frame, so the unanimated dismissal underneath is invisible.
        if DotMatrixTransitionCenter.shared.isEnabled, !isDismissing, let window = view.window {
            isDismissing = true
            let region = view.convert(scrollView.frame, to: window).integral
            DotMatrixCrossfade.run(in: window, direction: .random, region: region,
                                   chromeFade: true, changes: {
                applyClosedState()
                window.layoutIfNeeded()
            }, completion: {
                self.dismiss(animated: false)
            })
            return
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn],
                       animations: applyClosedState) { _ in
            self.dismiss(animated: false)
        }
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            let distance = hypot(translation.x, translation.y)
            let progress = min(1, distance / 220)
            // Follow the finger, shrinking and dimming toward the dismiss threshold.
            scrollView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                .scaledBy(x: 1 - progress * 0.2, y: 1 - progress * 0.2)
            dimmingView.alpha = 1 - progress * 0.7
            closeButton.alpha = 1 - progress
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view)
            let distance = hypot(translation.x, translation.y)
            let speed = hypot(velocity.x, velocity.y)
            if gesture.state == .ended, distance > 110 || speed > 900 {
                flingAway(translation: translation, velocity: velocity)
            } else {
                UIView.animate(
                    withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.85,
                    initialSpringVelocity: 0.4, options: [.allowUserInteraction]
                ) {
                    self.scrollView.transform = .identity
                    self.dimmingView.alpha = 1
                    self.closeButton.alpha = 1
                }
            }
        default:
            break
        }
    }

    /// Continues the swipe off-screen and dismisses (no return-to-source — the image
    /// flies away in the gesture's direction, like Photos/Twitter image viewers).
    private func flingAway(translation: CGPoint, velocity: CGPoint) {
        guard !isDismissing else { return }
        isDismissing = true
        let target = CGPoint(x: translation.x + velocity.x * 0.16, y: translation.y + velocity.y * 0.16)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.scrollView.transform = CGAffineTransform(translationX: target.x, y: target.y)
                .scaledBy(x: 0.8, y: 0.8)
            self.dimmingView.alpha = 0
            self.closeButton.alpha = 0
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

    public func contextMenuInteraction(
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
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view !== closeButton
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // The dismiss drag is only available zoomed all the way out; while zoomed in,
        // a pan should scroll the image instead.
        if gestureRecognizer === dismissPan {
            return scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 && !isDismissing
        }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === dismissPan || other === dismissPan
    }
}
