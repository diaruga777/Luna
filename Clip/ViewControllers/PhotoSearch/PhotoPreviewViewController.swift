//
//  PhotoPreviewViewController.swift
//  clipper
//

import Photos
import UIKit

/// Shows a single photo at full size. Pushed when a grid cell is tapped.
final class PhotoPreviewViewController: UIViewController {

    private let asset: PHAsset
    private let imageManager: PHImageManager
    private let imageView = UIImageView()
    private var requestID: PHImageRequestID?

    init(asset: PHAsset, imageManager: PHImageManager) {
        self.asset = asset
        self.imageManager = imageManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        requestID = imageManager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, _ in
            if let image { self?.imageView.image = image }
        }
    }

    deinit {
        if let requestID {
            imageManager.cancelImageRequest(requestID)
        }
    }
}
