//
//  EmailLoginShared.swift
//  Luna
//
//  Visual language and small helpers shared by the email sign-in surfaces
//  (`CredentialViewController`, and the inline address field in Settings →
//  Email): the hero/title/body/field-card treatment, the filled action
//  button, the provider badge chip, the OAuth presentation-context anchor, and
//  the invalid-input shake.
//

import LunaMailAccount
import LunaDesignSystem
import AuthenticationServices
import UIKit

enum EmailLoginUI {
    /// The brand-accent rounded icon tile, 96pt, sized to share the screen with
    /// the field card below it.
    static func heroTile(symbol: String) -> UIView {
        let tile = UIView()
        tile.backgroundColor = GlassStyle.lunaBrandAccent
        tile.layer.cornerRadius = 24
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        let glyph = UIImageView(image: UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)))
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        // Wrapped in a centering container: the screens' vertical stacks use
        // `.fill` alignment, which would otherwise stretch the tile's required
        // 96pt width to the full stack width.
        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(tile)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 96),
            tile.heightAnchor.constraint(equalToConstant: 96),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            tile.topAnchor.constraint(equalTo: wrapper.topAnchor),
            tile.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            tile.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
        ])
        return wrapper
    }

    static func titleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 28, weight: .bold)
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    static func bodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = LunaColors.secondaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    /// A rounded `LunaColors.secondaryBackground` card the text field sits inside,
    /// matching the comfortable 52-56pt row height used elsewhere for tappable
    /// list-like rows.
    static func fieldCard() -> UIView {
        let card = UIView()
        card.backgroundColor = LunaColors.secondaryBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 54).isActive = true
        return card
    }

    /// A small tertiary-tinted leading glyph for a field card (envelope, key, …).
    static func leadingGlyph(_ symbol: String) -> UIImageView {
        let icon = UIImageView(image: UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)))
        icon.tintColor = LunaColors.tertiaryText
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        return icon
    }
}

/// The filled accent action button (Sign In): 52pt tall, white 19pt semibold
/// title, `GlassStyle.lunaBrandAccent` fill, cornerRadius 14. Disabling dims to
/// 50% alpha (the stock disabled state barely dims a solid fill).
final class EmailLoginActionButton: UIButton {
    private let spinner = HorizonSpinnerView(side: 20)
    private var restingTitle: String

    init(title: String) {
        restingTitle = title
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
        setTitleColor(.white, for: .normal)
        backgroundColor = GlassStyle.lunaBrandAccent
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 52).isActive = true

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAlpha()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { updateAlpha() }
    }
    private func updateAlpha() { alpha = isEnabled ? 1 : 0.5 }

    /// Swaps the title for the embedded spinner and blocks taps while `loading`.
    /// Restoring real enablement afterward (based on the caller's own validation
    /// state) is the caller's job — this only undoes the title swap.
    func setLoading(_ loading: Bool) {
        setTitle(loading ? "" : restingTitle, for: .normal)
        isUserInteractionEnabled = !loading
        if loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }
}

/// The chip text for a known provider, or nil to hide the badge — `.generic`
/// covers both unrecognized domains and the empty field (no "@" → no domain →
/// `.generic`), so one check handles both "hidden" cases the design calls for.
enum ProviderBadgeText {
    static func text(for providerID: MailProvider.ID) -> String? {
        providerID == .generic ? nil : MailProvider.provider(for: providerID).displayName
    }
}

/// A small capsule chip ("Gmail", "iCloud", …) inside a field card. Always laid
/// out at its natural size and only ever faded via `alpha` — never added/removed
/// or constraint-shifted — so it never causes a layout jump when it appears.
final class ProviderBadgeView: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = GlassStyle.lunaBrandAccent.withAlphaComponent(0.15)
        label.textColor = GlassStyle.lunaBrandAccent
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        alpha = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    /// `nil` fades the chip out; a name fades it in (updating the text first so
    /// it never flashes the wrong provider mid-fade).
    func setProvider(_ text: String?) {
        if let text { label.text = text }
        UIView.animate(withDuration: 0.15) {
            self.alpha = text == nil ? 0 : 1
        }
    }
}

/// Anchors an `ASWebAuthenticationSession` to the presenting window.
final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var anchor: UIWindow?
    init(anchor: UIWindow?) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}

extension UIView {
    /// A small horizontal shake to signal invalid input.
    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [-8, 8, -6, 6, -3, 3, 0]
        animation.duration = 0.4
        layer.add(animation, forKey: "shake")
    }
}
