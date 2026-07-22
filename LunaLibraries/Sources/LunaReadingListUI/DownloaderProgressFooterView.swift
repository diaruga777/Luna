//
//  DownloaderProgressFooterView.swift
//  Luna
//

import LunaDesignSystem
import LunaMediaDownload
import UIKit

/// A footer pinned to the bottom of the Downloader grid, mirroring the visual
/// language of the download Live Activity and the action extension's inline
/// preview: a thumbnail + title + status-message row, with the moon-horizon
/// progress bar spanning the full width below. Purely informational (touches
/// pass through, same as `MediaDownloadStatusView`) — cancel/resume still
/// happen from the grid cell's own controls. Tracks whichever Downloader-owned
/// job is currently in flight via `.downloaderJobProgressChanged`; auto-hides
/// shortly after a finish or failure.
public final class DownloaderProgressFooterView: UIView {
    private let bar = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let thumbnail = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let progress = MoonHorizonProgressBar()
    private var trackedURLString: String?
    private var hideWorkItem: DispatchWorkItem?
    /// The footer tracks a single job at a time, and that job's thumbnail file
    /// doesn't change mid-download — so `apply(_:)`, called on every progress tick,
    /// only needs to decode once per job and reuse the bitmap for the rest of its ticks.
    private var cachedThumbnailFileName: String?
    private var cachedThumbnailImage: UIImage?

    public init() {
        super.init(frame: .zero)
        // Pass every touch through — purely informational, same contract as
        // MediaDownloadStatusView.
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        alpha = 0

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.clipsToBounds = true
        if #available(iOS 26.0, *) {
            bar.cornerConfiguration = .corners(radius: .fixed(18))
        } else {
            bar.layer.cornerRadius = 18
            bar.layer.cornerCurve = .continuous
        }
        addSubview(bar)

        thumbnail.layer.cornerRadius = 8
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.clipsToBounds = true
        thumbnail.backgroundColor = LunaColors.secondaryBackground
        thumbnail.tintColor = LunaColors.secondaryText
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 1

        messageLabel.font = .systemFont(ofSize: 13, weight: .regular)
        messageLabel.textColor = LunaColors.secondaryText
        messageLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [thumbnail, textStack])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center

        progress.translatesAutoresizingMaskIntoConstraints = false

        let column = UIStackView(arrangedSubviews: [row, progress])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: bar.contentView.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor, constant: -10),
            thumbnail.widthAnchor.constraint(equalToConstant: 40),
            thumbnail.heightAnchor.constraint(equalToConstant: 40),
            progress.heightAnchor.constraint(equalToConstant: 20),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Adopts whichever job is currently untracked (idle footer), then follows
    /// that job's URL exclusively until it finishes/fails/is canceled — other
    /// jobs' updates are ignored in the meantime so the footer doesn't flicker
    /// between concurrent downloads.
    @objc private func handleJobChanged(_ notification: Notification) {
        guard let urlString = notification.userInfo?["sourceURLString"] as? String else { return }
        let snapshot = notification.userInfo?["snapshot"] as? DownloaderJobSnapshot
        if trackedURLString == nil, snapshot != nil {
            trackedURLString = urlString
        }
        guard trackedURLString == urlString else { return }
        if let snapshot {
            apply(snapshot)
        } else {
            hide(immediately: true)
        }
    }

    private func apply(_ snapshot: DownloaderJobSnapshot) {
        hideWorkItem?.cancel()
        titleLabel.text = snapshot.title
        messageLabel.text = snapshot.message
        messageLabel.textColor = snapshot.phase == .failed ? .systemRed : LunaColors.secondaryText
        let thumbnailImage: UIImage?
        if let fileName = snapshot.thumbnailFileName {
            if fileName != cachedThumbnailFileName {
                cachedThumbnailFileName = fileName
                cachedThumbnailImage = UIImage(
                    contentsOfFile: LiveMediaDownloadAssets.thumbnailURL(fileName: fileName).path)
            }
            thumbnailImage = cachedThumbnailImage
        } else {
            thumbnailImage = nil
        }
        if let thumbnailImage {
            thumbnail.image = thumbnailImage
            thumbnail.contentMode = .scaleAspectFill
        } else {
            thumbnail.image = UIImage(systemName: snapshot.phase == .failed
                ? "exclamationmark.triangle.fill" : "arrow.down.circle")
            thumbnail.contentMode = .center
        }
        progress.isHidden = snapshot.phase == .failed
        progress.setProgress(Float(snapshot.progress), animated: true)
        reveal()

        if snapshot.phase == .finished || snapshot.phase == .failed {
            let work = DispatchWorkItem { [weak self] in self?.hide(immediately: false) }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
        }
    }

    private func reveal() {
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
    }

    private func hide(immediately: Bool) {
        trackedURLString = nil
        hideWorkItem?.cancel()
        UIView.animate(withDuration: immediately ? 0.15 : 0.3) { self.alpha = 0 }
    }
}
