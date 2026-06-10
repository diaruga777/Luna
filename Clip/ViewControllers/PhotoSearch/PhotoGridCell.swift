//
//  PhotoGridCell.swift
//  clipper
//

import Photos
import UIKit

/// A square thumbnail cell. Loads its image asynchronously via a shared caching
/// image manager and cancels any in-flight request when reused so async results
/// never land in the wrong cell.
final class PhotoGridCell: UICollectionViewCell {

    static let reuseID = "PhotoGridCell"

    private let imageView = UIImageView()
    private var requestID: PHImageRequestID?
    private weak var imageManager: PHImageManager?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(asset: PHAsset, imageManager: PHImageManager, targetSize: CGSize, options: PHImageRequestOptions) {
        self.imageManager = imageManager
        // Same targetSize/contentMode/options as the prefetch caching so this hits
        // the warmed cache and returns instantly.
        requestID = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let image else { return }
            // PHImageManager may call back off the main thread; update UI on main.
            DispatchQueue.main.async {
                self?.imageView.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let requestID {
            imageManager?.cancelImageRequest(requestID)
        }
        requestID = nil
        imageView.image = nil
    }
}
