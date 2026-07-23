//
//  OnboardingAnimationView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// A small looping illustration shown atop an onboarding step, depicting the
/// iOS change the step asks the user to make (enable the Safari extension, install
/// or assign the Action Button shortcut, receive a notification). Purely cosmetic;
/// `start()` lazily builds the illustration and kicks the loop when the step appears.
public final class OnboardingAnimationView: UIView {

    /// The Luna app identity shown in the miniature system UI. Live onboarding
    /// derives this from the host app by default; the guide-video recorder passes
    /// each case explicitly so every standalone app gets a matching PiP clip.
    public enum AppIcon: CaseIterable {
        case luna
        case reader
        case downloader
        case priceTracker

        public static var currentBundle: AppIcon {
            let identifier = Bundle.main.bundleIdentifier ?? ""
            if identifier.contains(".downloader") { return .downloader }
            if identifier.contains(".pricetracker") { return .priceTracker }
            if identifier.contains(".reader") { return .reader }
            return .luna
        }

        fileprivate var assetName: String {
            switch self {
            case .luna: return "AppIconImageLuna"
            case .reader: return "AppIconImageReader"
            case .downloader: return "AppIconImageDownloader"
            case .priceTracker: return "AppIconImagePriceTracker"
            }
        }

        /// Stable suffix used by the build-time recorder and the bundled guide
        /// filenames (for example, `SafariExtensionGuideDownloader.mp4`).
        public var guideVideoSuffix: String {
            switch self {
            case .luna: return "Luna"
            case .reader: return "Reader"
            case .downloader: return "Downloader"
            case .priceTracker: return "PriceTracker"
            }
        }
    }

    public enum Kind {
        case notification         // a banner sliding in
        case actionButton         // the Action Button pressed → Dynamic Island confirmation
        case actionExtension      // Safari → Share → "Save to Luna" action → reader
        case safariExtension      // Safari → page-menu → Manage Extensions → enable Luna
        case shortcutInstall      // Share sheet → Shortcuts app → install bundled shortcut
        case actionButtonSettings // Settings > Action Button → pick Shortcut → "Send To Luna"

        /// The length, in seconds, of exactly one repeating cycle of this kind's
        /// animation (i.e. the `duration:` passed to its `animateKeyframes` call,
        /// not counting the one-time initial delay before the loop starts). A
        /// video recorder can wait out the initial delay plus one loop, then
        /// capture exactly `loopDuration` seconds for a seamless clip.
        public var loopDuration: TimeInterval {
            switch self {
            case .notification: return 3.0
            case .actionButton: return 3.0
            case .actionExtension: return 6.5
            case .safariExtension: return 6.8
            case .shortcutInstall: return 5.5
            case .actionButtonSettings: return 10.5
            }
        }
    }

    private let kind: Kind
    private let appIcon: AppIcon
    let accent = GlassStyle.lunaBrandAccent
    private var didBuildIllustration = false

    /// True while this view's loop is meant to be animating (set by `start()`, cleared
    /// by `stop()`) — distinct from whether CAAnimations are actually PRESENT, since
    /// UIKit silently strips repeating keyframe animations when the app backgrounds.
    /// Gates the foreground restart below so a view that was never started (e.g. an
    /// off-screen onboarding step preloaded but not yet reached) doesn't spontaneously
    /// start animating just because the app came back to the foreground.
    private var isRunning = false
    private var foregroundObserver: NSObjectProtocol?

    public init(kind: Kind, appIcon: AppIcon = .currentBundle) {
        self.kind = kind
        self.appIcon = appIcon
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The phone facsimiles are portrait, so they get taller canvases; the
        // action-extension demo is the largest (≈ half the screen).
        let height: CGFloat
        let width: CGFloat
        switch kind {
        case .actionExtension: height = 360; width = 220
        case .safariExtension: height = 360; width = 220
        case .shortcutInstall: height = 300; width = 220
        case .actionButtonSettings: height = 360; width = 220
        case .actionButton: height = 230; width = 260
        default: height = 150; width = 260
        }
        heightAnchor.constraint(equalToConstant: height).isActive = true
        widthAnchor.constraint(equalToConstant: width).isActive = true
        clipsToBounds = true
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Begins (or restarts) the looping animation. Safe to call repeatedly.
    public func start() {
        isRunning = true
        buildIfNeeded()
        resetAnimationTree()
        switch kind {
        case .notification: animateNotification()
        case .actionButton: animateActionButton()
        case .actionExtension: animateActionExtension()
        case .safariExtension: animateSafariExtension()
        case .shortcutInstall: animateShortcutInstall()
        case .actionButtonSettings: animateActionButtonSettings()
        }
    }

    /// Stops any repeating UIKit animations before a step is hidden or restarted.
    /// Re-entering onboarding from Safari/Settings can otherwise stack multiple
    /// keyframe loops on the same phone mockup.
    public func stop() {
        isRunning = false
        resetAnimationTree()
    }

    /// `UIView.animateKeyframes(..., options: [.repeat])` loops are removed by UIKit
    /// when the app backgrounds, so simply returning to onboarding shows a frozen
    /// mockup — nothing re-adds the CAAnimations on its own. Restart from scratch
    /// (`start()` resets the animation tree first, so this can't stack loops) whenever
    /// the app becomes active while this view is both in a window and was actually
    /// running before the app backgrounded.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            installForegroundObserverIfNeeded()
        } else {
            removeForegroundObserver()
        }
    }

    private func installForegroundObserverIfNeeded() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning, self.window != nil else { return }
            self.start()
        }
    }

    private func removeForegroundObserver() {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        foregroundObserver = nil
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    private func resetAnimationTree() {
        func clear(_ view: UIView) {
            view.layer.removeAllAnimations()
            view.subviews.forEach(clear)
        }
        clear(self)
    }

    private func buildIfNeeded() {
        guard !didBuildIllustration else { return }
        didBuildIllustration = true
        switch kind {
        case .notification: buildNotification()
        case .actionButton: buildActionButton()
        case .actionExtension: buildActionExtension()
        case .safariExtension: buildSafariExtension()
        case .shortcutInstall: buildShortcutInstall()
        case .actionButtonSettings: buildActionButtonSettings()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    func lunaAppIconImage() -> UIImage? {
        // MUST load the plain `AppIconImage<App>` imageset: app icon sets cannot be
        // loaded through `UIImage(named:)`. These imagesets mirror the standard app
        // icons precisely for in-UI use.
        return UIImage(named: appIcon.assetName)
    }

    // MARK: - Per-scene illustration state
    //
    // Each scene's views/constraints live here (rather than beside its
    // build*()/animate*() pair in the per-scene extension file) because Swift
    // extensions cannot declare stored properties; internal (not private) so
    // those extension files can reach them.

    // MARK: - Notification banner

    let banner = UIView()

    // MARK: - Action Button (portrait phone running Safari)

    let pressRipple = UIView()
    let island = UIView()
    let islandIcon = UIImageView()
    let islandCheck = UIImageView(image: UIImage(
        systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
    var islandWidthConstraint: NSLayoutConstraint!
    var islandHeightConstraint: NSLayoutConstraint!
    let islandCompactSize = CGSize(width: 34, height: 10)
    let islandExpandedSize = CGSize(width: 74, height: 17)

    // MARK: - Action extension (Safari → Share → "Save to Luna" → reader)

    let axShareRipple = UIView()
    let axShareSheet = UIView()
    let axRowScroll = UIView()   // clips the scrolling action list
    let axRowList = UIStackView()
    let axReadHighlight = UIView()
    let axActionCard = UIView()

    // MARK: - Safari extension (Safari → page menu → Extensions → enable Luna)

    let sxMenuRipple = UIView()
    let sxMenuShell = UIView()
    let sxManageHighlight = UIView()
    let sxExtShell = UIView()
    var sxToggle: (track: UIView, thumb: UIView)!

    // MARK: - Shortcut install (Share sheet → Shortcuts app → install)

    let siShareRipple = UIView()
    let siShareSheet = UIView()
    let siShortcutIcon = UIView()
    let siShortcutRipple = UIView()

    // MARK: - Action Button Settings (Settings > Action Button)

    let abSettingsScreen = UIView()
    let abRootSettingsScreen = UIView()
    let abActionButtonRowHighlight = UIView()
    let abSafariScreen = UIView()
    let abActionCapsule = UIView()
    // The carousel is two horizontally-sliding glyph strips sharing one set of
    // slot positions: a dim strip on the Settings screen and a white copy inside
    // the clipping capsule. Panning both one slot moves each glyph between the
    // side positions and the capsule window, exactly like the real screen.
    let abOuterGlyphStrip = UIView()
    let abInnerGlyphStrip = UIView()
    let abCarouselStep: CGFloat = 64
    let abDotControls = UIView()
    let abDotShortcut = UIView()
    let abControlsTitle = UILabel()
    let abControlsSubtitle = UILabel()
    let abShortcutTitle = UILabel()
    let abShortcutSubtitle = UILabel()
    let abChooseButton = UIView()
    let abLunaChoice = UIView()
    let abHardwareButton = UIView()
    let abPressRipple = UIView()
    let abIsland = UIView()
    let abIslandIcon = UIImageView()
    let abIslandCheck = UIImageView(image: UIImage(
        systemName: "checkmark.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
    var abIslandWidth: NSLayoutConstraint!
    var abIslandHeight: NSLayoutConstraint!

}
