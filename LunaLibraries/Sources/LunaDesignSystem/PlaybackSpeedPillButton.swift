//
//  PlaybackSpeedPillButton.swift
//  LunaDesignSystem
//
//  The ONE playback-speed control for Luna's own players: a little glass pill
//  reading "1×" that opens a menu of `PlaybackSpeed.options` on a single tap.
//
//  It floats over media the way the card's mute button does, so it keeps that
//  control's dark fallback fill on OS versions without Liquid Glass — a pure
//  translucent pill over a bright video frame is unreadable.
//

import LunaModels
import UIKit

public final class PlaybackSpeedPillButton: UIButton {

    /// Called with the speed the user picked (never for a re-pick of the
    /// current one — the menu reports only changes).
    public var onSelectSpeed: ((Double) -> Void)?

    /// The speed shown on the pill and checked in its menu.
    public var speed: Double = PlaybackSpeed.normal {
        didSet {
            guard !PlaybackSpeed.matches(speed, oldValue) else { return }
            applySpeed()
        }
    }

    public init() {
        super.init(frame: .zero)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
            configuration.baseBackgroundColor = LunaSurfacePalette.glassTint
        } else {
            configuration = .plain()
            configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        }
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: 12, bottom: 6, trailing: 12)
        self.configuration = configuration
        showsMenuAsPrimaryAction = true
        applySpeed()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    private func applySpeed() {
        var attributes = AttributeContainer()
        attributes.font = .systemFont(ofSize: 13, weight: .semibold)
        configuration?.attributedTitle = AttributedString(
            PlaybackSpeed.label(for: speed), attributes: attributes)
        accessibilityLabel = L10n.string("Common_playbackSpeed")
        accessibilityValue = PlaybackSpeed.accessibilityLabel(for: speed)
        // The menu carries the checkmark, so it is rebuilt whenever the speed
        // changes rather than mutating actions in place.
        menu = UIMenu(
            title: L10n.string("Common_playbackSpeedMenuTitle"),
            children: PlaybackSpeed.options.map { option in
                let action = UIAction(title: PlaybackSpeed.label(for: option)) {
                    [weak self] _ in
                    self?.select(option)
                }
                action.state = PlaybackSpeed.matches(option, speed) ? .on : .off
                return action
            })
    }

    private func select(_ option: Double) {
        guard !PlaybackSpeed.matches(option, speed) else { return }
        speed = option
        onSelectSpeed?(option)
    }

    #if DEBUG
    /// Picks a speed through the same path the menu's own action takes.
    func selectSpeedForTesting(_ option: Double) { select(option) }

    /// The speeds the menu offers and which one carries the checkmark.
    var menuOptionsForTesting: [(speed: Double, isChecked: Bool)] {
        (menu?.children ?? []).compactMap { element in
            guard let action = element as? UIAction,
                  let option = PlaybackSpeed.options.first(where: {
                      PlaybackSpeed.label(for: $0) == action.title
                  })
            else { return nil }
            return (option, action.state == .on)
        }
    }
    #endif
}
