//
//  LunaColors.swift
//  Luna
//

import UIKit

/// Luna's semantic palette.
///
/// Both appearances are night. Dark mode is true black with white text. Light
/// mode is the *predawn* theme: the same near-black sky lifted by one barely
/// perceptible notch and given a faint chromatic cast — the app's own tint
/// cooled toward the blue of the first pre-sunrise light (see
/// `LunaSurfacePalette.predawnSurface(level:)`). It is not a light theme and
/// never carries dark-on-light text; the two appearances differ only by that
/// lift and cast, so "Light" reads as the sky a few minutes before sunrise
/// rather than as a different app.
///
/// Keeping these colors semantic lets System mode and the in-app appearance
/// switch update existing views without rebuilding their hierarchy.
public enum LunaColors {
    /// The night sky. Dark mode is true black; predawn sits one notch above it.
    public static let background = night(dark: 0.00, predawn: 0.055)
    public static let secondaryBackground = night(dark: 0.07, predawn: 0.105)
    public static let tertiaryBackground = night(dark: 0.12, predawn: 0.150)

    public static let groupedBackground = background
    public static let secondaryGroupedBackground = secondaryBackground
    public static let tertiaryGroupedBackground = tertiaryBackground

    /// Both appearances are dark, so text is light in both. Predawn text is a
    /// hair softer than dark mode's pure white, matching its lifted sky.
    public static let primaryText = dynamic(darkWhite: 1.00, lightWhite: 0.97)
    public static let secondaryText = dynamic(darkWhite: 0.78, lightWhite: 0.76)
    public static let tertiaryText = dynamic(darkWhite: 0.62, lightWhite: 0.61)
    public static let quaternaryText = dynamic(darkWhite: 0.48, lightWhite: 0.48)

    public static let separator = dynamic(
        dark: UIColor(white: 1, alpha: 0.18),
        light: UIColor(white: 1, alpha: 0.16))
    public static let opaqueSeparator = night(dark: 0.22, predawn: 0.24)

    /// The failure accent: a failed card's rim glow, its detail line, and its
    /// destructive affordances. `.systemRed` is tuned for white surfaces and
    /// reads muddy on Luna's near-black bases, so both ends are pinned by hand —
    /// bright enough on black to read as a glow, and only marginally tempered on
    /// the slightly lifted predawn sky.
    public static let errorAccent = dynamic(
        dark: UIColor(red: 1.00, green: 0.36, blue: 0.33, alpha: 1),
        light: UIColor(red: 1.00, green: 0.40, blue: 0.36, alpha: 1))

    public static let fill = dynamic(
        dark: UIColor(white: 1, alpha: 0.20),
        light: UIColor(white: 1, alpha: 0.18))
    public static let secondaryFill = dynamic(
        dark: UIColor(white: 1, alpha: 0.16),
        light: UIColor(white: 1, alpha: 0.14))
    public static let tertiaryFill = dynamic(
        dark: UIColor(white: 1, alpha: 0.12),
        light: UIColor(white: 1, alpha: 0.11))
    public static let quaternaryFill = dynamic(
        dark: UIColor(white: 1, alpha: 0.08),
        light: UIColor(white: 1, alpha: 0.07))

    /// A surface pair on the same 0…1 brightness scale in both appearances: a
    /// neutral gray when dark, the tinted predawn equivalent when light.
    static func night(dark: CGFloat, predawn: CGFloat) -> UIColor {
        UIColor { traits in
            traits.lunaSky == .night
                ? UIColor(white: dark, alpha: 1)
                : LunaSurfacePalette.predawnSurface(level: predawn)
        }
    }

    private static func dynamic(darkWhite: CGFloat, lightWhite: CGFloat) -> UIColor {
        dynamic(
            dark: UIColor(white: darkWhite, alpha: 1),
            light: UIColor(white: lightWhite, alpha: 1))
    }

    /// Keyed on `LunaSkyTrait`, not `userInterfaceStyle` — see `LunaSky` for why
    /// the style itself stays pinned to `.dark` app-wide.
    private static func dynamic(dark: UIColor, light: UIColor) -> UIColor {
        UIColor { traits in traits.lunaSky == .night ? dark : light }
    }

    /// Covers UIKit-owned surfaces whose colors are not assigned by Luna code.
    /// Call before constructing a scene's root view controller.
    public static func installGlobalAppearance() {
        UITableView.appearance().backgroundColor = groupedBackground
        UITableViewCell.appearance().backgroundColor = secondaryGroupedBackground
        UICollectionView.appearance().backgroundColor = background
        UITextView.appearance().backgroundColor = background
        UITextView.appearance().textColor = primaryText
        UITextField.appearance().backgroundColor = secondaryBackground
        UITextField.appearance().textColor = primaryText

        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = background
        navigation.titleTextAttributes = [.foregroundColor: primaryText]
        navigation.largeTitleTextAttributes = [.foregroundColor: primaryText]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = background
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}
