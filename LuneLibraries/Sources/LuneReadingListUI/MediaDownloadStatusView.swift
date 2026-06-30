//
//  MediaDownloadStatusView.swift
//  Lune
//

import LuneDesignSystem
import UIKit

/// A non-blocking media-download status pill pinned to the bottom of the reading
/// list. It shows download progress and the final result WITHOUT capturing touches
/// (so the list stays fully interactive), and — because it's a subview of the
/// reading list view, not the window — it never shows over the reader. Auto-hides
/// after a result.
public final class MediaDownloadStatusView: UIView {

    private let pill = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let icon = UIImageView()
    private let label = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private var hideWorkItem: DispatchWorkItem?

    public init() {
        super.init(frame: .zero)
        // Pass every touch through to the list — purely informational.
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.clipsToBounds = true
        if #available(iOS 26.0, *) {
            pill.cornerConfiguration = .capsule()
        } else {
            pill.layer.cornerRadius = 24
        }
        addSubview(pill)

        icon.tintColor = GlassStyle.readingAccent
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label

        progress.progressTintColor = GlassStyle.readingAccent
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [icon, label, progress])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.heightAnchor.constraint(equalToConstant: 48),
            row.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: pill.contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
        ])
        alpha = 0
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the pill with an indeterminate-looking 0 progress and a "saving" label.
    public func startProgress() {
        hideWorkItem?.cancel()
        icon.image = UIImage(systemName: "arrow.down.circle")
        icon.tintColor = GlassStyle.readingAccent
        label.text = "Saving media…"
        progress.isHidden = false
        progress.progress = 0
        reveal()
    }

    public func update(progress value: Double) {
        progress.setProgress(Float(value), animated: true)
    }

    /// Shows the final result, then auto-hides.
    public func showResult(message: String, success: Bool) {
        hideWorkItem?.cancel()
        progress.isHidden = true
        icon.image = UIImage(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        icon.tintColor = success ? GlassStyle.readingAccent : .systemRed
        label.text = message
        reveal()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    private func reveal() {
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
    }

    private func dismiss() {
        UIView.animate(withDuration: 0.3) { self.alpha = 0 }
    }
}
