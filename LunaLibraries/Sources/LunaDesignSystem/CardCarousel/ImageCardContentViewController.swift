//
//  ImageCardContentViewController.swift
//  LunaDesignSystem
//
//  Static (non-time-based) card content: one aspect-fit image, loaded either
//  synchronously or through an async loader (disk decode, Photos request, …).
//

import UIKit

public final class ImageCardContentViewController: CardContentViewController {

    /// Supplies the image asynchronously; call the completion on any queue.
    public typealias Loader = (@escaping (UIImage?) -> Void) -> Void

    private let loader: Loader
    private let imageView = UIImageView()

    public init(image: UIImage?) {
        self.loader = { completion in completion(image) }
        super.init()
    }

    public init(loader: @escaping Loader) {
        self.loader = loader
        super.init()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
        loader { [weak self] image in
            DispatchQueue.main.async { self?.imageView.image = image }
        }
    }
}
