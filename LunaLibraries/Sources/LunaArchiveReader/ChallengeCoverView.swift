//
//  ChallengeCoverView.swift
//  LunaArchiveReader
//

import LunaDesignSystem
import UIKit

/// The opaque cover a challenge flow keeps over its live web view.
///
/// A flow that has to run a real page — the archive unlock, a plugin's browser
/// step — shows the page only while it is asking the user something. The rest of
/// the time this covers it: the raw page is the site's business, not the user's,
/// and an uncovered one reads as Luna having lost its place. `isHidden` is the
/// whole of the control; there is no translucent state.
///
/// The layout is `LoadingStatusLayout`, the same one the extensions' wait screen
/// uses, so a flow handed over from an extension does not appear to jump.
public final class ChallengeCoverView: UIView {

    /// Runs while the flow is working. A terminal message stops it.
    public let spinner = HorizonSpinnerView(side: 36)
    /// The line under the spinner. A caller cycles it or sets it outright.
    public let label = EclipseBloomStatusLabel()
    /// Hidden until a terminal message needs an escape hatch under it.
    public let actionButton = UIButton(type: .system)

    /// - Parameters:
    ///   - actionTitle: the escape button's title.
    ///   - actionSymbol: its SF Symbol name.
    public init(actionTitle: String, actionSymbol: String) {
        super.init(frame: .zero)
        // The cover COVERS. Its background is a hair off opaque only so the
        // loading controls composite crisply over it.
        backgroundColor = LunaColors.background.withAlphaComponent(0.99)
        translatesAutoresizingMaskIntoConstraints = false

        spinner.startAnimating()

        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = actionTitle
        configuration.image = UIImage(systemName: actionSymbol)
        configuration.imagePadding = 6
        configuration.cornerStyle = .large
        actionButton.configuration = configuration
        actionButton.isHidden = true

        LoadingStatusLayout.install(
            spinner: spinner, label: label, action: actionButton, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Adds this cover over `parent` and pins it to every edge.
    public func cover(_ parent: UIView) {
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }
}
