//
//  LunaColors.swift
//  Luna
//

import UIKit

/// Luna's semantic palette.
///
/// Dark mode remains true black with white text. Light mode is intentionally a
/// lighter dark theme: its base gray is the darkest neutral that still gives
/// black normal-sized text at least a 4.5:1 WCAG contrast ratio. Keeping these
/// colors semantic lets System mode and the in-app appearance switch update
/// existing views without rebuilding their hierarchy.
public enum LunaColors {
    /// 46% sRGB gray. Black text resolves to approximately 4.58:1 contrast.
    public static let background = dynamic(darkWhite: 0.00, lightWhite: 0.46)
    public static let secondaryBackground = dynamic(darkWhite: 0.07, lightWhite: 0.51)
    public static let tertiaryBackground = dynamic(darkWhite: 0.12, lightWhite: 0.56)

    public static let groupedBackground = background
    public static let secondaryGroupedBackground = secondaryBackground
    public static let tertiaryGroupedBackground = tertiaryBackground

    public static let primaryText = dynamic(darkWhite: 1.00, lightWhite: 0.00)
    public static let secondaryText = dynamic(darkWhite: 0.78, lightWhite: 0.00)
    public static let tertiaryText = dynamic(darkWhite: 0.62, lightWhite: 0.00)
    public static let quaternaryText = dynamic(darkWhite: 0.48, lightWhite: 0.00)

    public static let separator = dynamic(
        dark: UIColor(white: 1, alpha: 0.18),
        light: UIColor(white: 0, alpha: 0.28))
    public static let opaqueSeparator = dynamic(darkWhite: 0.22, lightWhite: 0.30)

    /// The failure accent: a failed card's rim glow, its detail line, and its
    /// destructive affordances. `.systemRed` is tuned for white surfaces and
    /// reads muddy on Luna's true-black and 46%-gray bases, so both ends are
    /// pinned by hand — bright enough on black to read as a glow, saturated
    /// enough on gray to read as a warning.
    public static let errorAccent = dynamic(
        dark: UIColor(red: 1.00, green: 0.36, blue: 0.33, alpha: 1),
        light: UIColor(red: 0.78, green: 0.09, blue: 0.07, alpha: 1))

    public static let fill = dynamic(
        dark: UIColor(white: 1, alpha: 0.20),
        light: UIColor(white: 0, alpha: 0.20))
    public static let secondaryFill = dynamic(
        dark: UIColor(white: 1, alpha: 0.16),
        light: UIColor(white: 0, alpha: 0.16))
    public static let tertiaryFill = dynamic(
        dark: UIColor(white: 1, alpha: 0.12),
        light: UIColor(white: 0, alpha: 0.12))
    public static let quaternaryFill = dynamic(
        dark: UIColor(white: 1, alpha: 0.08),
        light: UIColor(white: 0, alpha: 0.08))

    private static func dynamic(darkWhite: CGFloat, lightWhite: CGFloat) -> UIColor {
        dynamic(
            dark: UIColor(white: darkWhite, alpha: 1),
            light: UIColor(white: lightWhite, alpha: 1))
    }

    private static func dynamic(dark: UIColor, light: UIColor) -> UIColor {
        UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
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
