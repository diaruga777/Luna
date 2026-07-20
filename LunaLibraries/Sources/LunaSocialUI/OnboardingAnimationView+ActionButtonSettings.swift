//
//  OnboardingAnimationView+ActionButtonSettings.swift
//  Luna
//

import LunaDesignSystem
import UIKit

extension OnboardingAnimationView {

    // MARK: - Action Button Settings (Settings > Action Button)

    /// One carousel glyph at the Action Button screen's standard symbol size.
    private func abCarouselGlyph(_ symbol: String, tint: UIColor) -> UIImageView {
        let glyph = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
        glyph.tintColor = tint
        glyph.translatesAutoresizingMaskIntoConstraints = false
        return glyph
    }

    /// Recreates the real Action Button Settings presentation from device references:
    /// circular back button, tall titanium phone, large illuminated hardware control,
    /// neighboring action glyphs, page dots, and the selected shortcut. The second page
    /// is Safari so the guide demonstrates the complete job rather than ending as soon
    /// as Settings is configured.
    func buildActionButtonSettings() {
        let phone = UIView()
        phone.backgroundColor = .systemGray4
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 30
        phone.layer.cornerCurve = .continuous
        phone.clipsToBounds = true
        phone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phone)

        abSettingsScreen.backgroundColor = .systemBackground
        abSettingsScreen.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(abSettingsScreen)

        let time = UILabel()
        time.text = "9:41"
        time.font = .systemFont(ofSize: 8, weight: .semibold)
        time.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(time)
        let statusIsland = UIView()
        statusIsland.backgroundColor = .black
        statusIsland.layer.cornerRadius = 6
        statusIsland.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(statusIsland)
        let status = UIImageView(image: UIImage(
            systemName: "wifi", withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)))
        status.tintColor = .label
        status.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(status)

        let backCircle = UIView()
        backCircle.backgroundColor = .tertiarySystemFill
        backCircle.layer.cornerRadius = 13
        backCircle.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(backCircle)
        let backChevron = UIImageView(image: UIImage(
            systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
        backChevron.tintColor = .label
        backChevron.translatesAutoresizingMaskIntoConstraints = false
        backCircle.addSubview(backChevron)

        let device = UIView()
        device.backgroundColor = .secondarySystemBackground
        device.layer.cornerRadius = 42
        device.layer.cornerCurve = .continuous
        device.layer.borderColor = UIColor.separator.cgColor
        device.layer.borderWidth = 1
        device.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(device)
        let deviceGlow = UIView()
        deviceGlow.backgroundColor = UIColor.systemGray.withAlphaComponent(0.22)
        deviceGlow.layer.cornerRadius = 32
        deviceGlow.translatesAutoresizingMaskIntoConstraints = false
        device.addSubview(deviceGlow)

        // Slots left→right: the previous action, Controls (starts in the capsule
        // window), Shortcut, then Accessibility waiting one slot further out.
        let carouselSymbols = ["flashlight.on.fill", "switch.2", "square.stack.3d.up.fill", "accessibility"]
        abOuterGlyphStrip.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(abOuterGlyphStrip)

        // The capsule is a sibling of (not inside) `device` so it stacks above the
        // dim strip; fully opaque so that strip never ghosts through, and clipping
        // so the white strip only shows through the capsule window.
        abActionCapsule.backgroundColor = accent
        abActionCapsule.layer.cornerRadius = 25
        abActionCapsule.layer.cornerCurve = .continuous
        abActionCapsule.layer.borderColor = accent.withAlphaComponent(0.65).cgColor
        abActionCapsule.layer.borderWidth = 3
        abActionCapsule.clipsToBounds = true
        abActionCapsule.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(abActionCapsule)
        abInnerGlyphStrip.translatesAutoresizingMaskIntoConstraints = false
        abActionCapsule.addSubview(abInnerGlyphStrip)

        var glyphConstraints: [NSLayoutConstraint] = []
        for (index, symbol) in carouselSymbols.enumerated() {
            let offset = CGFloat(index - 1) * abCarouselStep
            let outer = abCarouselGlyph(symbol, tint: .tertiaryLabel)
            abOuterGlyphStrip.addSubview(outer)
            let inner = abCarouselGlyph(symbol, tint: .white)
            abInnerGlyphStrip.addSubview(inner)
            glyphConstraints += [
                outer.centerXAnchor.constraint(equalTo: abOuterGlyphStrip.centerXAnchor, constant: offset),
                outer.centerYAnchor.constraint(equalTo: abOuterGlyphStrip.centerYAnchor),
                inner.centerXAnchor.constraint(equalTo: abInnerGlyphStrip.centerXAnchor, constant: offset),
                inner.centerYAnchor.constraint(equalTo: abInnerGlyphStrip.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(glyphConstraints)

        let dots = UIStackView()
        dots.axis = .horizontal
        dots.spacing = 5
        dots.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<10 {
            let dot: UIView
            switch index {
            case 7: dot = abDotControls
            case 8: dot = abDotShortcut
            default: dot = UIView()
            }
            dot.backgroundColor = index == 7 ? .label : .tertiaryLabel
            dot.layer.cornerRadius = 2.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
            dots.addArrangedSubview(dot)
        }
        abSettingsScreen.addSubview(dots)

        // Titles and subtitles come as per-page pairs crossfaded by alpha: setting
        // `.text` inside a keyframe block applies immediately at setup (text is
        // not animatable), so a single mutated label never visibly changes pages.
        func configurePageTitle(_ label: UILabel, _ text: String) {
            label.text = text
            label.font = .systemFont(ofSize: 19, weight: .bold)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            abSettingsScreen.addSubview(label)
        }
        func configurePageSubtitle(_ label: UILabel, _ text: String) {
            label.text = text
            label.font = .systemFont(ofSize: 9)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            abSettingsScreen.addSubview(label)
        }
        configurePageTitle(abControlsTitle, "Controls")
        configurePageSubtitle(abControlsSubtitle, "Quickly access your favorite Control.")
        configurePageTitle(abShortcutTitle, "Shortcut")
        configurePageSubtitle(abShortcutSubtitle, "Open an app or run your\nfavorite shortcut.")

        // The choose button belongs to the Shortcut page only; it fades in after
        // the carousel lands there, so its label never needs to change.
        abChooseButton.backgroundColor = .systemBlue
        abChooseButton.layer.cornerRadius = 12
        abChooseButton.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(abChooseButton)
        let abChooseLabel = UILabel()
        abChooseLabel.text = "Choose a Shortcut…"
        abChooseLabel.textColor = .white
        abChooseLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        abChooseLabel.translatesAutoresizingMaskIntoConstraints = false
        abChooseButton.addSubview(abChooseLabel)

        abLunaChoice.backgroundColor = .tertiarySystemFill
        abLunaChoice.layer.cornerRadius = 12
        abLunaChoice.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(abLunaChoice)
        let lunaIcon = UIImageView(image: lunaAppIconImage())
        lunaIcon.layer.cornerRadius = 4
        lunaIcon.clipsToBounds = true
        lunaIcon.translatesAutoresizingMaskIntoConstraints = false
        let lunaName = UILabel()
        lunaName.text = "Send To Luna"
        lunaName.font = .systemFont(ofSize: 10, weight: .semibold)
        let lunaStack = UIStackView(arrangedSubviews: [lunaIcon, lunaName])
        lunaStack.spacing = 6
        lunaStack.alignment = .center
        lunaStack.translatesAutoresizingMaskIntoConstraints = false
        abLunaChoice.addSubview(lunaStack)

        // Root Settings page shown first, matching the real navigation path. It
        // pushes left after a visible tap on Action Button.
        abRootSettingsScreen.backgroundColor = .systemGroupedBackground
        abRootSettingsScreen.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(abRootSettingsScreen)
        let rootTime = UILabel()
        rootTime.text = "9:41"
        rootTime.font = .systemFont(ofSize: 8, weight: .semibold)
        rootTime.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(rootTime)
        let rootIsland = UIView()
        rootIsland.backgroundColor = .black
        rootIsland.layer.cornerRadius = 6
        rootIsland.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(rootIsland)
        let rootStatus = UIImageView(image: UIImage(
            systemName: "wifi", withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)))
        rootStatus.tintColor = .label
        rootStatus.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(rootStatus)
        let rootTitle = UILabel()
        rootTitle.text = "Settings"
        rootTitle.font = .systemFont(ofSize: 17, weight: .bold)
        rootTitle.textAlignment = .center
        rootTitle.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(rootTitle)

        func rootRow(symbol: String, title: String, color: UIColor) -> UIView {
            let row = UIView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 29).isActive = true
            let tile = UIView()
            tile.backgroundColor = color
            tile.layer.cornerRadius = 5
            tile.translatesAutoresizingMaskIntoConstraints = false
            let icon = UIImageView(image: UIImage(
                systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
            icon.tintColor = .white
            icon.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(icon)
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 11)
            label.translatesAutoresizingMaskIntoConstraints = false
            let chevron = UIImageView(image: UIImage(
                systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold)))
            chevron.tintColor = .tertiaryLabel
            chevron.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(tile)
            row.addSubview(label)
            row.addSubview(chevron)
            let divider = UIView()
            divider.backgroundColor = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(divider)
            NSLayoutConstraint.activate([
                tile.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8), tile.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                tile.widthAnchor.constraint(equalToConstant: 20), tile.heightAnchor.constraint(equalToConstant: 20),
                icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8), chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                divider.leadingAnchor.constraint(equalTo: label.leadingAnchor), divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: row.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 0.5),
            ])
            return row
        }

        let connectivityGroup = UIView()
        connectivityGroup.backgroundColor = .secondarySystemGroupedBackground
        connectivityGroup.layer.cornerRadius = 12
        connectivityGroup.clipsToBounds = true
        connectivityGroup.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(connectivityGroup)
        let connectivityRows = UIStackView(arrangedSubviews: [
            // Wi-Fi, not Bluetooth: SF Symbols has no Bluetooth rune, and every
            // bolt stand-in reads as the Messenger logo at this size.
            rootRow(symbol: "wifi", title: "Wi-Fi", color: .systemBlue),
            rootRow(symbol: "antenna.radiowaves.left.and.right", title: "Cellular", color: .systemGreen),
            rootRow(symbol: "battery.100percent", title: "Battery", color: .systemGreen),
        ])
        connectivityRows.axis = .vertical
        connectivityRows.translatesAutoresizingMaskIntoConstraints = false
        connectivityGroup.addSubview(connectivityRows)

        let systemGroup = UIView()
        systemGroup.backgroundColor = .secondarySystemGroupedBackground
        systemGroup.layer.cornerRadius = 12
        systemGroup.clipsToBounds = true
        systemGroup.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(systemGroup)
        let generalRow = rootRow(symbol: "gear", title: "General", color: .systemGray)
        let accessibilityRow = rootRow(symbol: "accessibility", title: "Accessibility", color: .systemBlue)
        let actionButtonRow = rootRow(symbol: "button.horizontal.top.press", title: "Action Button", color: .systemBlue)
        let appearanceRow = rootRow(symbol: "circle.lefthalf.filled", title: "Appearance", color: .black)
        let systemRows = UIStackView(arrangedSubviews: [generalRow, accessibilityRow, actionButtonRow, appearanceRow])
        systemRows.axis = .vertical
        systemRows.translatesAutoresizingMaskIntoConstraints = false
        systemGroup.addSubview(systemRows)
        abActionButtonRowHighlight.backgroundColor = .systemGray.withAlphaComponent(0.28)
        abActionButtonRowHighlight.layer.cornerRadius = 6
        abActionButtonRowHighlight.alpha = 0
        abActionButtonRowHighlight.translatesAutoresizingMaskIntoConstraints = false
        systemGroup.insertSubview(abActionButtonRowHighlight, belowSubview: systemRows)

        // Safari page used after setup: gray-box website, correct bottom safe-area
        // order, physical-button feedback, and a Dynamic Island save confirmation.
        abSafariScreen.backgroundColor = .secondarySystemBackground
        abSafariScreen.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(abSafariScreen)
        let webLines = UIStackView(arrangedSubviews: [
            bar(width: 0.72, height: 10, color: .label.withAlphaComponent(0.65)),
            bar(width: 0.94, height: 5), bar(width: 0.86, height: 5),
            bar(width: 0.91, height: 5), bar(width: 0.64, height: 5),
        ])
        webLines.axis = .vertical
        webLines.spacing = 8
        webLines.alignment = .fill
        webLines.setCustomSpacing(15, after: webLines.arrangedSubviews[0])
        webLines.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(webLines)
        let safariChrome = UIView()
        safariChrome.backgroundColor = .systemBackground
        safariChrome.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(safariChrome)
        let urlPill = UIView()
        urlPill.backgroundColor = .secondarySystemBackground
        urlPill.layer.cornerRadius = 10
        urlPill.translatesAutoresizingMaskIntoConstraints = false
        safariChrome.addSubview(urlPill)
        let urlText = UILabel()
        urlText.text = "example.com"
        urlText.font = .systemFont(ofSize: 8, weight: .medium)
        urlText.textColor = .secondaryLabel
        urlText.translatesAutoresizingMaskIntoConstraints = false
        urlPill.addSubview(urlText)
        let chromeIcons = UIStackView(arrangedSubviews: [toolbarIcon("chevron.left"), toolbarIcon("chevron.right"),
                                                          toolbarIcon("square.and.arrow.up"), toolbarIcon("square.on.square")])
        chromeIcons.axis = .horizontal
        chromeIcons.distribution = .equalSpacing
        chromeIcons.translatesAutoresizingMaskIntoConstraints = false
        safariChrome.addSubview(chromeIcons)
        let home = UIView()
        home.backgroundColor = .label
        home.layer.cornerRadius = 1.5
        home.translatesAutoresizingMaskIntoConstraints = false
        safariChrome.addSubview(home)
        abHardwareButton.backgroundColor = .systemGray
        abHardwareButton.layer.cornerRadius = 2
        abHardwareButton.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(abHardwareButton)
        abPressRipple.backgroundColor = accent.withAlphaComponent(0.38)
        abPressRipple.layer.cornerRadius = 22
        abPressRipple.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(abPressRipple)

        abIsland.backgroundColor = .black
        abIsland.layer.cornerRadius = 6
        abIsland.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(abIsland)
        abIslandIcon.image = lunaAppIconImage()
        abIslandIcon.contentMode = .scaleAspectFit
        abIslandIcon.layer.cornerRadius = 3
        abIslandIcon.clipsToBounds = true
        abIslandIcon.translatesAutoresizingMaskIntoConstraints = false
        abIsland.addSubview(abIslandIcon)
        abIslandCheck.tintColor = .systemGreen
        abIslandCheck.contentMode = .scaleAspectFit
        abIslandCheck.translatesAutoresizingMaskIntoConstraints = false
        abIsland.addSubview(abIslandCheck)
        abIslandWidth = abIsland.widthAnchor.constraint(equalToConstant: 34)
        abIslandHeight = abIsland.heightAnchor.constraint(equalToConstant: 12)

        NSLayoutConstraint.activate([
            phone.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            phone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            phone.centerXAnchor.constraint(equalTo: centerXAnchor),
            phone.widthAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.49),
            abSettingsScreen.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            abSettingsScreen.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            abSettingsScreen.topAnchor.constraint(equalTo: phone.topAnchor),
            abSettingsScreen.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            time.leadingAnchor.constraint(equalTo: abSettingsScreen.leadingAnchor, constant: 14),
            time.topAnchor.constraint(equalTo: abSettingsScreen.topAnchor, constant: 10),
            statusIsland.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor),
            statusIsland.topAnchor.constraint(equalTo: abSettingsScreen.topAnchor, constant: 8),
            statusIsland.widthAnchor.constraint(equalToConstant: 46), statusIsland.heightAnchor.constraint(equalToConstant: 13),
            status.trailingAnchor.constraint(equalTo: abSettingsScreen.trailingAnchor, constant: -14),
            status.centerYAnchor.constraint(equalTo: time.centerYAnchor),
            backCircle.leadingAnchor.constraint(equalTo: abSettingsScreen.leadingAnchor, constant: 10),
            backCircle.topAnchor.constraint(equalTo: abSettingsScreen.topAnchor, constant: 34),
            backCircle.widthAnchor.constraint(equalToConstant: 26), backCircle.heightAnchor.constraint(equalToConstant: 26),
            backChevron.centerXAnchor.constraint(equalTo: backCircle.centerXAnchor), backChevron.centerYAnchor.constraint(equalTo: backCircle.centerYAnchor),
            device.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor),
            device.topAnchor.constraint(equalTo: abSettingsScreen.topAnchor, constant: 70),
            device.widthAnchor.constraint(equalToConstant: 80), device.heightAnchor.constraint(equalToConstant: 134),
            deviceGlow.centerXAnchor.constraint(equalTo: device.centerXAnchor), deviceGlow.centerYAnchor.constraint(equalTo: device.centerYAnchor),
            deviceGlow.widthAnchor.constraint(equalToConstant: 66), deviceGlow.heightAnchor.constraint(equalToConstant: 120),
            abActionCapsule.centerXAnchor.constraint(equalTo: device.centerXAnchor), abActionCapsule.centerYAnchor.constraint(equalTo: device.centerYAnchor),
            abActionCapsule.widthAnchor.constraint(equalToConstant: 48), abActionCapsule.heightAnchor.constraint(equalToConstant: 76),
            abOuterGlyphStrip.centerXAnchor.constraint(equalTo: abActionCapsule.centerXAnchor),
            abOuterGlyphStrip.centerYAnchor.constraint(equalTo: abActionCapsule.centerYAnchor),
            abOuterGlyphStrip.widthAnchor.constraint(equalToConstant: 0), abOuterGlyphStrip.heightAnchor.constraint(equalToConstant: 0),
            abInnerGlyphStrip.centerXAnchor.constraint(equalTo: abActionCapsule.centerXAnchor),
            abInnerGlyphStrip.centerYAnchor.constraint(equalTo: abActionCapsule.centerYAnchor),
            abInnerGlyphStrip.widthAnchor.constraint(equalToConstant: 0), abInnerGlyphStrip.heightAnchor.constraint(equalToConstant: 0),
            dots.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), dots.topAnchor.constraint(equalTo: device.bottomAnchor, constant: 9),
            abControlsTitle.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abControlsTitle.topAnchor.constraint(equalTo: dots.bottomAnchor, constant: 9),
            abShortcutTitle.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abShortcutTitle.topAnchor.constraint(equalTo: dots.bottomAnchor, constant: 9),
            abControlsSubtitle.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abControlsSubtitle.topAnchor.constraint(equalTo: abControlsTitle.bottomAnchor, constant: 4),
            abControlsSubtitle.leadingAnchor.constraint(greaterThanOrEqualTo: abSettingsScreen.leadingAnchor, constant: 10),
            abControlsSubtitle.trailingAnchor.constraint(lessThanOrEqualTo: abSettingsScreen.trailingAnchor, constant: -10),
            abShortcutSubtitle.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abShortcutSubtitle.topAnchor.constraint(equalTo: abControlsTitle.bottomAnchor, constant: 4),
            abShortcutSubtitle.leadingAnchor.constraint(greaterThanOrEqualTo: abSettingsScreen.leadingAnchor, constant: 10),
            abShortcutSubtitle.trailingAnchor.constraint(lessThanOrEqualTo: abSettingsScreen.trailingAnchor, constant: -10),
            abChooseButton.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abChooseButton.topAnchor.constraint(equalTo: abShortcutSubtitle.bottomAnchor, constant: 9),
            abChooseButton.widthAnchor.constraint(equalToConstant: 112), abChooseButton.heightAnchor.constraint(equalToConstant: 26),
            abChooseLabel.centerXAnchor.constraint(equalTo: abChooseButton.centerXAnchor), abChooseLabel.centerYAnchor.constraint(equalTo: abChooseButton.centerYAnchor),
            abLunaChoice.centerXAnchor.constraint(equalTo: abChooseButton.centerXAnchor), abLunaChoice.centerYAnchor.constraint(equalTo: abChooseButton.centerYAnchor),
            abLunaChoice.widthAnchor.constraint(equalTo: abChooseButton.widthAnchor), abLunaChoice.heightAnchor.constraint(equalTo: abChooseButton.heightAnchor),
            lunaStack.centerXAnchor.constraint(equalTo: abLunaChoice.centerXAnchor), lunaStack.centerYAnchor.constraint(equalTo: abLunaChoice.centerYAnchor),
            lunaIcon.widthAnchor.constraint(equalToConstant: 18), lunaIcon.heightAnchor.constraint(equalToConstant: 18),

            abRootSettingsScreen.leadingAnchor.constraint(equalTo: phone.leadingAnchor), abRootSettingsScreen.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            abRootSettingsScreen.topAnchor.constraint(equalTo: phone.topAnchor), abRootSettingsScreen.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            rootTime.leadingAnchor.constraint(equalTo: abRootSettingsScreen.leadingAnchor, constant: 14), rootTime.topAnchor.constraint(equalTo: abRootSettingsScreen.topAnchor, constant: 10),
            rootIsland.centerXAnchor.constraint(equalTo: abRootSettingsScreen.centerXAnchor), rootIsland.topAnchor.constraint(equalTo: abRootSettingsScreen.topAnchor, constant: 8),
            rootIsland.widthAnchor.constraint(equalToConstant: 46), rootIsland.heightAnchor.constraint(equalToConstant: 13),
            rootStatus.trailingAnchor.constraint(equalTo: abRootSettingsScreen.trailingAnchor, constant: -14), rootStatus.centerYAnchor.constraint(equalTo: rootTime.centerYAnchor),
            rootTitle.centerXAnchor.constraint(equalTo: abRootSettingsScreen.centerXAnchor), rootTitle.topAnchor.constraint(equalTo: abRootSettingsScreen.topAnchor, constant: 34),
            connectivityGroup.topAnchor.constraint(equalTo: rootTitle.bottomAnchor, constant: 12),
            connectivityGroup.leadingAnchor.constraint(equalTo: abRootSettingsScreen.leadingAnchor, constant: 10),
            connectivityGroup.trailingAnchor.constraint(equalTo: abRootSettingsScreen.trailingAnchor, constant: -10),
            connectivityRows.leadingAnchor.constraint(equalTo: connectivityGroup.leadingAnchor), connectivityRows.trailingAnchor.constraint(equalTo: connectivityGroup.trailingAnchor),
            connectivityRows.topAnchor.constraint(equalTo: connectivityGroup.topAnchor), connectivityRows.bottomAnchor.constraint(equalTo: connectivityGroup.bottomAnchor),
            systemGroup.topAnchor.constraint(equalTo: connectivityGroup.bottomAnchor, constant: 12),
            systemGroup.leadingAnchor.constraint(equalTo: connectivityGroup.leadingAnchor), systemGroup.trailingAnchor.constraint(equalTo: connectivityGroup.trailingAnchor),
            systemRows.leadingAnchor.constraint(equalTo: systemGroup.leadingAnchor), systemRows.trailingAnchor.constraint(equalTo: systemGroup.trailingAnchor),
            systemRows.topAnchor.constraint(equalTo: systemGroup.topAnchor), systemRows.bottomAnchor.constraint(equalTo: systemGroup.bottomAnchor),
            abActionButtonRowHighlight.leadingAnchor.constraint(equalTo: actionButtonRow.leadingAnchor, constant: 3),
            abActionButtonRowHighlight.trailingAnchor.constraint(equalTo: actionButtonRow.trailingAnchor, constant: -3),
            abActionButtonRowHighlight.topAnchor.constraint(equalTo: actionButtonRow.topAnchor, constant: 2),
            abActionButtonRowHighlight.bottomAnchor.constraint(equalTo: actionButtonRow.bottomAnchor, constant: -2),

            abSafariScreen.leadingAnchor.constraint(equalTo: phone.leadingAnchor), abSafariScreen.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            abSafariScreen.topAnchor.constraint(equalTo: phone.topAnchor), abSafariScreen.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            webLines.topAnchor.constraint(equalTo: abSafariScreen.topAnchor, constant: 48),
            webLines.leadingAnchor.constraint(equalTo: abSafariScreen.leadingAnchor, constant: 14), webLines.trailingAnchor.constraint(equalTo: abSafariScreen.trailingAnchor, constant: -14),
            safariChrome.leadingAnchor.constraint(equalTo: abSafariScreen.leadingAnchor), safariChrome.trailingAnchor.constraint(equalTo: abSafariScreen.trailingAnchor),
            safariChrome.bottomAnchor.constraint(equalTo: abSafariScreen.bottomAnchor), safariChrome.heightAnchor.constraint(equalToConstant: 72),
            urlPill.topAnchor.constraint(equalTo: safariChrome.topAnchor, constant: 5), urlPill.leadingAnchor.constraint(equalTo: safariChrome.leadingAnchor, constant: 12),
            urlPill.trailingAnchor.constraint(equalTo: safariChrome.trailingAnchor, constant: -12), urlPill.heightAnchor.constraint(equalToConstant: 22),
            urlText.centerXAnchor.constraint(equalTo: urlPill.centerXAnchor), urlText.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
            chromeIcons.topAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: 7), chromeIcons.leadingAnchor.constraint(equalTo: safariChrome.leadingAnchor, constant: 18),
            chromeIcons.trailingAnchor.constraint(equalTo: safariChrome.trailingAnchor, constant: -18), chromeIcons.heightAnchor.constraint(equalToConstant: 16),
            home.centerXAnchor.constraint(equalTo: safariChrome.centerXAnchor), home.bottomAnchor.constraint(equalTo: safariChrome.bottomAnchor, constant: -5),
            home.widthAnchor.constraint(equalToConstant: 56), home.heightAnchor.constraint(equalToConstant: 3),
            abHardwareButton.leadingAnchor.constraint(equalTo: abSafariScreen.leadingAnchor, constant: -1), abHardwareButton.topAnchor.constraint(equalTo: abSafariScreen.topAnchor, constant: 72),
            abHardwareButton.widthAnchor.constraint(equalToConstant: 5), abHardwareButton.heightAnchor.constraint(equalToConstant: 30),
            abPressRipple.centerXAnchor.constraint(equalTo: abHardwareButton.centerXAnchor), abPressRipple.centerYAnchor.constraint(equalTo: abHardwareButton.centerYAnchor),
            abPressRipple.widthAnchor.constraint(equalToConstant: 44), abPressRipple.heightAnchor.constraint(equalToConstant: 44),
            abIsland.centerXAnchor.constraint(equalTo: abSafariScreen.centerXAnchor), abIsland.topAnchor.constraint(equalTo: abSafariScreen.topAnchor, constant: 9),
            abIslandWidth, abIslandHeight,
            abIslandIcon.leadingAnchor.constraint(equalTo: abIsland.leadingAnchor, constant: 8), abIslandIcon.centerYAnchor.constraint(equalTo: abIsland.centerYAnchor),
            abIslandIcon.widthAnchor.constraint(equalToConstant: 14), abIslandIcon.heightAnchor.constraint(equalToConstant: 14),
            abIslandCheck.trailingAnchor.constraint(equalTo: abIsland.trailingAnchor, constant: -8), abIslandCheck.centerYAnchor.constraint(equalTo: abIsland.centerYAnchor),
            abIslandCheck.widthAnchor.constraint(equalToConstant: 16), abIslandCheck.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func animateActionButtonSettings() {
        layoutIfNeeded()
        let screenWidth = abSettingsScreen.bounds.width
        let pageOffscreen = CGAffineTransform(translationX: screenWidth + 8, y: 0)
        let settingsCardLeft = CGAffineTransform(
            translationX: -screenWidth * 0.27, y: 0).scaledBy(x: 0.55, y: 0.55)
        let safariCardRight = CGAffineTransform(
            translationX: screenWidth * 0.27, y: 0).scaledBy(x: 0.55, y: 0.55)

        func reset() {
            abRootSettingsScreen.transform = .identity
            abRootSettingsScreen.alpha = 1
            abActionButtonRowHighlight.alpha = 0
            abSettingsScreen.transform = pageOffscreen
            abSettingsScreen.layer.cornerRadius = 0
            abSettingsScreen.clipsToBounds = true
            abOuterGlyphStrip.transform = .identity
            abInnerGlyphStrip.transform = .identity
            abDotControls.backgroundColor = .label
            abDotShortcut.backgroundColor = .tertiaryLabel
            abControlsTitle.alpha = 1
            abControlsSubtitle.alpha = 1
            abShortcutTitle.alpha = 0
            abShortcutSubtitle.alpha = 0
            abChooseButton.alpha = 0
            abChooseButton.transform = .identity
            abLunaChoice.alpha = 0
            abLunaChoice.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            abSafariScreen.transform = pageOffscreen
            abSafariScreen.layer.cornerRadius = 18
            abSafariScreen.clipsToBounds = true
            abHardwareButton.backgroundColor = .systemGray
            abHardwareButton.transform = .identity
            abPressRipple.alpha = 0
            abPressRipple.transform = CGAffineTransform(scaleX: 0.25, y: 0.25)
            abIslandWidth.constant = 34
            abIslandHeight.constant = 12
            abIsland.layer.cornerRadius = 6
            abIslandIcon.alpha = 0
            abIslandCheck.alpha = 0
            abIslandCheck.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            layoutIfNeeded()
        }
        reset()

        // Snapshot/layout tests intentionally disable UIKit animations. Preserve
        // the useful first frame (Settings root) instead of synchronously applying
        // every keyframe and leaving only the gray app-switcher background.
        guard UIView.areAnimationsEnabled else { return }

        UIView.animateKeyframes(withDuration: 10.5, delay: 0.4, options: [.repeat, .calculationModeCubic]) {
            // Tap Action Button on the Settings root.
            UIView.addKeyframe(withRelativeStartTime: 0.07, relativeDuration: 0.06) {
                self.abActionButtonRowHighlight.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.13, relativeDuration: 0.10) {
                self.abActionButtonRowHighlight.alpha = 0
                self.abRootSettingsScreen.transform = CGAffineTransform(translationX: -screenWidth * 0.34, y: 0)
                self.abRootSettingsScreen.alpha = 0
                self.abSettingsScreen.transform = .identity
            }
            // Swipe the carousel one slot: both glyph strips pan together, so
            // Controls slides out of the capsule window into the dim side slot
            // while Shortcut slides in — the way real Settings pans — and the
            // page dot advances with it.
            UIView.addKeyframe(withRelativeStartTime: 0.28, relativeDuration: 0.12) {
                let pan = CGAffineTransform(translationX: -self.abCarouselStep, y: 0)
                self.abOuterGlyphStrip.transform = pan
                self.abInnerGlyphStrip.transform = pan
                self.abDotControls.backgroundColor = .tertiaryLabel
                self.abDotShortcut.backgroundColor = .label
                self.abControlsTitle.alpha = 0
                self.abControlsSubtitle.alpha = 0
            }
            // Only once the carousel has landed on Shortcut do its title,
            // subtitle, and the "Choose a Shortcut…" button belong on screen.
            UIView.addKeyframe(withRelativeStartTime: 0.36, relativeDuration: 0.06) {
                self.abShortcutTitle.alpha = 1
                self.abShortcutSubtitle.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.40, relativeDuration: 0.05) {
                self.abChooseButton.alpha = 1
            }
            // Choose the installed Luna shortcut.
            UIView.addKeyframe(withRelativeStartTime: 0.46, relativeDuration: 0.06) {
                self.abChooseButton.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.52, relativeDuration: 0.07) {
                self.abChooseButton.alpha = 0
                self.abChooseButton.transform = .identity
                self.abLunaChoice.alpha = 1
                self.abLunaChoice.transform = .identity
            }
            // iOS multitasking transition: both apps become inset cards over the
            // gray switcher background, Settings exits left as Safari enters from
            // the right, then Safari expands to the full device screen.
            UIView.addKeyframe(withRelativeStartTime: 0.62, relativeDuration: 0.05) {
                self.abSettingsScreen.transform = settingsCardLeft
                self.abSettingsScreen.layer.cornerRadius = 18
                self.abSafariScreen.transform = safariCardRight
            }
            // Explicitly pin the same values across the hold. UIKit otherwise
            // interpolates across an empty keyframe gap toward the next state.
            UIView.addKeyframe(withRelativeStartTime: 0.67, relativeDuration: 0.08) {
                self.abSettingsScreen.transform = settingsCardLeft
                self.abSettingsScreen.layer.cornerRadius = 18
                self.abSafariScreen.transform = safariCardRight
                self.abSafariScreen.layer.cornerRadius = 18
            }
            UIView.addKeyframe(withRelativeStartTime: 0.75, relativeDuration: 0.08) {
                self.abSettingsScreen.transform = CGAffineTransform(
                    translationX: -screenWidth * 1.05, y: 0).scaledBy(x: 0.84, y: 0.84)
                self.abSafariScreen.transform = .identity
                self.abSafariScreen.layer.cornerRadius = 0
            }
            // Press the physical Action Button: the button itself depresses and
            // lights up in the accent while a wide ripple blooms outward, so the
            // press registers instead of reading as a faint blink.
            UIView.addKeyframe(withRelativeStartTime: 0.84, relativeDuration: 0.03) {
                self.abHardwareButton.backgroundColor = self.accent
                self.abHardwareButton.transform = CGAffineTransform(translationX: 1.5, y: 0)
                self.abPressRipple.alpha = 1
                self.abPressRipple.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.87, relativeDuration: 0.04) {
                self.abPressRipple.alpha = 0
                self.abPressRipple.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.90, relativeDuration: 0.03) {
                self.abHardwareButton.backgroundColor = .systemGray
                self.abHardwareButton.transform = .identity
            }
            // The Dynamic Island expands into an oversized confirmation — larger
            // than real usage, deliberately, so the checkmark is unmissable —
            // and the checkmark pops in with a small overshoot.
            UIView.addKeyframe(withRelativeStartTime: 0.85, relativeDuration: 0.05) {
                self.abIslandWidth.constant = 84
                self.abIslandHeight.constant = 26
                self.abIsland.layer.cornerRadius = 13
                self.layoutIfNeeded()
            }
            UIView.addKeyframe(withRelativeStartTime: 0.90, relativeDuration: 0.03) {
                self.abIslandIcon.alpha = 1
                self.abIslandCheck.alpha = 1
                self.abIslandCheck.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.93, relativeDuration: 0.03) {
                self.abIslandCheck.transform = .identity
            }
            // Pin Safari (and the confirmation) in place through the hold: cubic
            // keyframe interpolation otherwise starts drifting toward the exit
            // keyframe early and drags the checkmark offscreen mid-confirmation.
            UIView.addKeyframe(withRelativeStartTime: 0.93, relativeDuration: 0.05) {
                self.abSafariScreen.transform = .identity
                self.abIslandIcon.alpha = 1
                self.abIslandCheck.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.98, relativeDuration: 0.02) {
                self.abSafariScreen.transform = CGAffineTransform(translationX: -screenWidth, y: 0)
                self.abIslandIcon.alpha = 0
                self.abIslandCheck.alpha = 0
            }
        }
    }

}
