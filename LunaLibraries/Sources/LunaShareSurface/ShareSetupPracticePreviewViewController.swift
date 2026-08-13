//
//  ShareSetupPracticePreviewViewController.swift
//  LunaShareSurface
//

import LunaDesignSystem
import LunaModels
import UIKit

/// How a rehearsal tells its host the user is done with it — the one thing every
/// rehearsal owes. The host presents the rehearsal, so conformers hold this weakly.
@MainActor
protocol ShareSetupPracticeDelegate: AnyObject {
    func shareSetupPracticeDidFinish(_ practice: UIViewController)
}

/// What every practice rehearsal owes its host: one way out. Which rehearsal a
/// practice link gets is `ShareViewController.practicePreview`.
@MainActor
protocol ShareSetupPracticePresenting: AnyObject {
    var completionDelegate: (any ShareSetupPracticeDelegate)? { get set }
}

/// The real extension-side counterpart of onboarding's mock preview. Practice
/// URLs never enter the saves list; both extension points show this bundled
/// content so the lesson is deterministic and works without a network fetch.
///
/// This is the ARTICLE rehearsal. The InstaTok practice link stands for a video
/// post and gets `ShareSetupPracticeDownloadViewController` instead.
@MainActor
final class ShareSetupPracticePreviewViewController: UIViewController,
    ShareSetupPracticePresenting {
    weak var completionDelegate: (any ShareSetupPracticeDelegate)?

    private let app: LunaApp
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    init(app: LunaApp) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        title = app.displayName
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_done"),
            style: .done,
            target: self,
            action: #selector(doneTapped))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        let icon = LunaAppIconView(app: app, side: 52)
        let titleLabel = label(
            ShareSetupPractice.title, size: 29, weight: .bold,
            color: LunaColors.primaryText)
        let byline = label(
            ShareSetupPractice.byline, size: 13, weight: .semibold,
            color: LunaColors.secondaryText)

        let hero = UIView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.backgroundColor = LunaSurfacePalette.baseColor.withAlphaComponent(0.20)
        hero.layer.cornerRadius = 18
        hero.layer.cornerCurve = .continuous
        let moon = UIImageView(image: UIImage(
            systemName: "moon.stars.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 58)))
        moon.translatesAutoresizingMaskIntoConstraints = false
        moon.tintColor = GlassStyle.readingAccent
        moon.contentMode = .scaleAspectFit
        hero.addSubview(moon)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let body = UILabel()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.numberOfLines = 0
        body.attributedText = NSAttributedString(
            string: ShareSetupPractice.plainText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17),
                .foregroundColor: LunaColors.primaryText,
                .paragraphStyle: paragraph,
            ])

        for child in [icon, titleLabel, byline, hero, body] {
            contentView.addSubview(child)
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            icon.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            byline.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            byline.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            byline.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            hero.topAnchor.constraint(equalTo: byline.bottomAnchor, constant: 18),
            hero.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            hero.heightAnchor.constraint(equalToConstant: 132),
            moon.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            moon.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            body.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32),
        ])
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: UIFont.Weight,
        color: UIColor
    ) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    @objc private func doneTapped() {
        completionDelegate?.shareSetupPracticeDidFinish(self)
    }
}
