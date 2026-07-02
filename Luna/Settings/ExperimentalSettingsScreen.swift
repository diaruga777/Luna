//
//  ExperimentalSettingsScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaYouTubeAPI
import LunaReaderUI
import LunaSemantic
import LunaDesignSystem
import LunaTransitions
import UIKit
import LunaContentRendering

/// Experimental features, off by default: on-device semantic sharing
/// suggestions, and YouTube integration (sign-in, playlist, auto-add).
final class ExperimentalSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable {
        case rabbitHole, semantic, paywallStrategies, archiveOverlay, dotMatrix, frostedGlass, jellystone, luna, youtube
    }
    private enum YouTubeRow: Int, CaseIterable { case signIn, playlist, autoAdd }
    private enum RabbitHoleRow: Int, CaseIterable { case toggle, reader, transition }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    #if DEBUG
    /// Maps a `-openEffect <name>` launch arg to an effect settings screen so the
    /// simulator harness can deep-link past the (un-automatable) settings toolbar.
    static func debugEffectScreen(named name: String?) -> UIViewController? {
        switch name?.lowercased() {
        case "dotmatrix", "halftone": return DotMatrixSettingsScreen()
        case "frosted", "frostedglass", "neon": return FrostedGlassSettingsScreen()
        case "jellystone", "jelly", "seaglass": return StoneSettingsScreen(material: .jellystone)
        case "luna": return StoneSettingsScreen(material: .luna)
        default: return nil
        }
    }
    #endif

    override func viewDidLoad() {
        headerTitle = "Experimental"
        super.viewDidLoad()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .rabbitHole: return RabbitHoleRow.allCases.count
        case .semantic: return 1
        case .paywallStrategies: return 1
        case .archiveOverlay: return 1
        case .dotMatrix: return 1
        case .frostedGlass: return 1
        case .jellystone: return 1
        case .luna: return 1
        case .youtube: return YouTubeRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .rabbitHole: return "Dot Matrix Transitions"
        case .semantic: return "Suggest Shares Based on Content"
        case .paywallStrategies: return "Extra Paywall Unlock Strategies"
        case .archiveOverlay: return "Archive Reader Cover"
        case .dotMatrix: return "Dot Matrix Effect"
        case .frostedGlass: return "Frosted Neon Effect"
        case .jellystone: return "Jellystone Effect"
        case .luna: return "Luna Effect"
        case .youtube: return "DEV ONLY: YouTube"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .rabbitHole:
            return "Off by default. Replaces every transition in the app — screen pushes, modals, and list changes — with a Dot Matrix \"pixel wipe\": the screen dissolves into spaced, rounded dots of where you're going, then sharpens into it, with the wave sweeping the way the motion would. It also opens saves in the experimental RabbitHole inline reader (dive into a link as a stacked layer; overscroll to pull the previous one back). One switch for both; flip it off to return to the standard animations and reader."
        case .semantic:
            return "When you save something that resembles things you've shared with a friend before, Luna can suggest sharing it with them. Slide all the way left to turn this off."
        case .paywallStrategies:
            return "Off by default. When on, Luna tries to unlock a paywalled article on-device — keeping cookies, blocking the site's metering scripts, spoofing the referrer a site unlocks for, and cleaning the page — before falling back to the archive reader. This unlocks many soft paywalls the archive can't, but adds a few seconds before the fallback. Turn it off to go straight to the archive reader."
        case .archiveOverlay:
            return "Opacity of overlay while we work to unlock web articles"
        case .dotMatrix:
            return "A real-time dot-matrix shader. Tune its parameters and preview it "
                + "on your own photos, videos, and GIFs; tap the preview to ripple it in."
        case .frostedGlass:
            return "A real-time \"neon lights through frosted glass\" shader, with its own "
                + "parameters, live preview, and tap-to-ripple wave."
        case .jellystone:
            return "A cheerful pastel sea-glass shader — fuzzy translucency fading from a "
                + "clear rim to a coloured centre. Tune it and preview on your own media."
        case .luna:
            return "A milky, semi-transparent luna shader, with its own parameters, live "
                + "preview, and tap-to-ripple wave."
        case .youtube:
            return "Sign in to find videos by channel and add saved videos to a playlist. Auto-added videos are marked read.\n\nYour email must be whitelisted for this to work while in development."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .rabbitHole:
            switch RabbitHoleRow(rawValue: indexPath.row)! {
            case .toggle: return rabbitHoleCell()
            case .reader: return rabbitHoleReaderCell()
            case .transition:
                return disclosureCell(title: "Dot Matrix Transition", symbol: "square.stack.3d.down.right")
            }
        case .semantic:
            return semanticSensitivityCell()
        case .paywallStrategies:
            return paywallStrategiesCell()
        case .archiveOverlay:
            return overlayAlphaCell()
        case .dotMatrix:
            return dotMatrixCell()
        case .frostedGlass:
            return frostedGlassCell()
        case .jellystone:
            return disclosureCell(title: "Jellystone Effect", symbol: "circle.hexagongrid.fill")
        case .luna:
            return disclosureCell(title: "Luna Effect", symbol: "diamond.fill")
        case .youtube:
            return youTubeCell(for: YouTubeRow(rawValue: indexPath.row)!)
        }
    }

    /// The global Dot Matrix pixel-wipe transitions toggle (the RabbitHole READER
    /// fork is the separate toggle below — they used to be one switch, which made
    /// the standard scroll reader and the wipes mutually exclusive).
    private func rabbitHoleCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Dot Matrix Transitions"
        cell.contentConfiguration = content
        cell.accessoryView = makeToggle(
            isOn: ReaderSettings.pixelWipeTransitionsEnabled,
            action: #selector(rabbitHoleToggled(_:)))
        return cell
    }

    @objc private func rabbitHoleToggled(_ toggle: UISwitch) {
        ReaderSettings.pixelWipeTransitionsEnabled = toggle.isOn
    }

    /// The forked stacked-layer RabbitHole reader (off ⇒ the standard scroll reader,
    /// which has its own pixel-wiped inline reader).
    private func rabbitHoleReaderCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "RabbitHole Reader"
        cell.contentConfiguration = content
        cell.accessoryView = makeToggle(
            isOn: ReaderSettings.rabbitHoleReaderEnabled,
            action: #selector(rabbitHoleReaderToggled(_:)))
        return cell
    }

    @objc private func rabbitHoleReaderToggled(_ toggle: UISwitch) {
        ReaderSettings.rabbitHoleReaderEnabled = toggle.isOn
    }

    /// A toggle that enables the on-device (non-archive) paywall-bypass strategies.
    private func paywallStrategiesCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Unlock Paywalls On-Device"
        cell.contentConfiguration = content
        cell.accessoryView = makeToggle(
            isOn: ReaderSettings.nonArchiveBypassEnabled,
            action: #selector(nonArchiveBypassToggled(_:)))
        return cell
    }

    @objc private func nonArchiveBypassToggled(_ toggle: UISwitch) {
        ReaderSettings.nonArchiveBypassEnabled = toggle.isOn
    }

    /// A slider for the archive-reader cover opacity (20%–99%, default 99%).
    private func overlayAlphaCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let slider = UISlider()
        slider.minimumValue = Float(ReaderSettings.archiveOverlayAlphaRange.lowerBound)
        slider.maximumValue = Float(ReaderSettings.archiveOverlayAlphaRange.upperBound)
        slider.value = Float(ReaderSettings.archiveOverlayAlpha)
        slider.addTarget(self, action: #selector(overlayAlphaChanged(_:)), for: .valueChanged)

        let endLabels = UIStackView(arrangedSubviews: [endCaption("20%"), UIView(), endCaption("99%")])
        endLabels.axis = .horizontal
        endLabels.distribution = .fill

        let stack = UIStackView(arrangedSubviews: [slider, endLabels])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
        ])
        return cell
    }

    @objc private func overlayAlphaChanged(_ sender: UISlider) {
        ReaderSettings.archiveOverlayAlpha = Double(sender.value)
    }

    /// A slider from "Never" (off) to "Often", with no exposed numbers.
    private func semanticSensitivityCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = Float(SemanticSharingSettings.sensitivity)
        slider.addTarget(self, action: #selector(sensitivityChanged(_:)), for: .valueChanged)

        let endLabels = UIStackView(arrangedSubviews: [
            endCaption("Never"), UIView(), endCaption("Often"),
        ])
        endLabels.axis = .horizontal
        endLabels.distribution = .fill

        let stack = UIStackView(arrangedSubviews: [slider, endLabels])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
        ])
        return cell
    }

    /// Disclosure row that drills into the Dot Matrix effect controls.
    private func dotMatrixCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Dot Matrix Effect"
        content.image = UIImage(systemName: "circle.grid.3x3.fill")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// Disclosure row that drills into the Frosted Neon effect controls.
    private func frostedGlassCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Frosted Neon Effect"
        content.image = UIImage(systemName: "lightspectrum.horizontal")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// A generic disclosure row that drills into an effect's controls.
    private func disclosureCell(title: String, symbol: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.image = UIImage(systemName: symbol)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func endCaption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        return label
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .rabbitHole:
            if RabbitHoleRow(rawValue: indexPath.row) == .transition {
                navigationController?.pushViewController(RabbitHoleTransitionSettingsScreen(), animated: true)
            }
        case .dotMatrix:
            navigationController?.pushViewController(DotMatrixSettingsScreen(), animated: true)
        case .frostedGlass:
            navigationController?.pushViewController(FrostedGlassSettingsScreen(), animated: true)
        case .jellystone:
            navigationController?.pushViewController(StoneSettingsScreen(material: .jellystone), animated: true)
        case .luna:
            navigationController?.pushViewController(StoneSettingsScreen(material: .luna), animated: true)
        case .youtube:
            switch YouTubeRow(rawValue: indexPath.row)! {
            case .signIn: signInTapped()
            case .playlist: choosePlaylistTapped()
            case .autoAdd: break
            }
        case .semantic, .paywallStrategies, .archiveOverlay:
            break
        }
    }

    @objc private func sensitivityChanged(_ sender: UISlider) {
        SemanticSharingSettings.sensitivity = Double(sender.value)
        // Build the index once it's on so live matches have history to compare to.
        if SemanticSharingSettings.isEnabled { SemanticIndexer.shared.scheduleRun() }
    }

    // MARK: - YouTube

    private func youTubeCell(for row: YouTubeRow) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        switch row {
        case .signIn:
            if GoogleAuthClient.shared.isSignedIn {
                content.text = "Sign Out of YouTube"
                content.textProperties.color = .systemRed
                content.image = UIImage(systemName: "person.crop.circle.badge.checkmark")
            } else {
                content.text = "Sign In to YouTube"
                content.textProperties.color = view.tintColor ?? .systemBlue
                content.image = UIImage(systemName: "person.crop.circle")
            }
        case .playlist:
            content.text = "Playlist"
            content.secondaryText = YouTubeSettings.playlistTitle ?? "None selected"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "text.badge.plus")
        case .autoAdd:
            content.text = "Auto-Add Saved Videos"
            cell.accessoryView = makeToggle(
                isOn: YouTubeSettings.autoAddToPlaylist, action: #selector(autoAddToggled(_:)))
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    @objc private func autoAddToggled(_ toggle: UISwitch) {
        YouTubeSettings.autoAddToPlaylist = toggle.isOn
    }

    private func signInTapped() {
        if GoogleAuthClient.shared.isSignedIn {
            GoogleAuthClient.shared.signOut()
            tableView.reloadData()
            return
        }
        Task { [weak self] in
            do {
                try await GoogleAuthClient.shared.signIn()
                self?.tableView.reloadData()
            } catch {
                self?.presentInfoAlert(title: "Sign-In Failed", message: "\(error)")
            }
        }
    }

    private func choosePlaylistTapped() {
        guard GoogleAuthClient.shared.isSignedIn else {
            presentInfoAlert(title: "Sign In First", message: "Sign in to YouTube to pick a playlist.")
            return
        }
        Task { [weak self] in
            do {
                let playlists = try await YouTubeAPIClient().listMyPlaylists()
                self?.presentPlaylistSheet(playlists)
            } catch {
                self?.presentInfoAlert(title: "Couldn't Load Playlists", message: "\(error)")
            }
        }
    }

    @MainActor
    private func presentPlaylistSheet(_ playlists: [YouTubePlaylist]) {
        let sheet = UIAlertController(title: "Add Videos To", message: nil, preferredStyle: .actionSheet)
        for playlist in playlists {
            sheet.addAction(UIAlertAction(title: playlist.title, style: .default) { [weak self] _ in
                YouTubeSettings.playlistID = playlist.id
                YouTubeSettings.playlistTitle = playlist.title
                self?.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: "Create \"Watch Later (Luna)\"", style: .default) { [weak self] _ in
            Task {
                do {
                    let created = try await YouTubeAPIClient().createPlaylist(title: "Watch Later (Luna)")
                    YouTubeSettings.playlistID = created.id
                    YouTubeSettings.playlistTitle = created.title
                    self?.tableView.reloadData()
                } catch {
                    self?.presentInfoAlert(title: "Couldn't Create Playlist", message: "\(error)")
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        DotMatrixModal.present(sheet, from: self)
    }
}
