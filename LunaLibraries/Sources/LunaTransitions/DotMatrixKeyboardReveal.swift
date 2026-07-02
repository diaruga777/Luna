//
//  DotMatrixKeyboardReveal.swift
//  LunaTransitions
//
//  Dot Matrix for the KEYBOARD's appearance. The keyboard is out-of-process content —
//  it can't be snapshotted, so the usual before→after wipe is impossible. Instead the
//  keyboard rises invisibly under a patch window pinned ABOVE the keyboard window that
//  holds the pre-keyboard pixels, and once the keyboard settles the patch runs the
//  engine's DISSOLVE-OUT mode: the old pixels pixelate into dots over transparent gaps
//  and fade away, revealing the live keyboard beneath. Very fast (0.15s) — the
//  keyboard is chased by the finger.
//
//  The patch's pixels come from what's actually VISIBLE at the keyboard's frame: the
//  modal cover's image when a `DotMatrixModal` choreography is up (the live window
//  already shows the fully-presented modal underneath it), otherwise the live window.
//
//  Installed once by the app with a window accessor (a closure so this library —
//  which also compiles into the extensions — never touches `UIApplication.shared`).
//  Only genuine docked-keyboard appearances wipe: frame CHANGES while visible
//  (predictive bar, emoji switch), hardware-keyboard bars and floating iPad keyboards
//  are ignored, and a hide mid-reveal tears the patch down instantly. The patch window
//  is touch-transparent so typing is never swallowed.
//

import LunaContentRendering
import LunaDesignSystem
import UIKit

public enum DotMatrixKeyboardReveal {

    /// The dissolve itself — deliberately the fastest wipe in the app.
    private static let dissolveDuration: TimeInterval = 0.15

    private static var windowProvider: (() -> UIWindow?)?
    private static var keyboardVisible = false
    private static var current: Reveal?
    private static var observersInstalled = false

    /// The modal cover currently on screen, set/cleared by `DotMatrixModal`. While a
    /// cover is up, the patch copies ITS pixels rather than the live window's.
    static weak var activeCover: DotMatrixCoverWindow?

    /// Wire the keyboard observers. Call once at app launch; `provider` returns the
    /// window keyboards appear over (the key window).
    public static func install(windowProvider provider: @escaping () -> UIWindow?) {
        windowProvider = provider
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification,
                           object: nil, queue: .main) { note in
            handleWillShow(note)
        }
        center.addObserver(forName: UIResponder.keyboardDidShowNotification,
                           object: nil, queue: .main) { _ in
            current?.keyboardDidShow()
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                           object: nil, queue: .main) { _ in
            keyboardVisible = false
            current?.cancel()
        }
    }

    private static func handleWillShow(_ note: Notification) {
        let wasVisible = keyboardVisible
        keyboardVisible = true
        // `DotMatrixModal` presents with `animated: false`, which UIKit runs with
        // animations transiently disabled — and a modal text field's keyboardWillShow
        // arrives inside that window. A live modal cover therefore counts as
        // animations-on; the bare check still skips test runs (globally disabled).
        let animationsAllowed = UIView.areAnimationsEnabled || activeCover != nil
        guard !wasVisible,                       // an appearance, not a frame change
              current == nil,
              animationsAllowed,
              DotMatrixTransitionCenter.shared.isEnabled,
              let window = windowProvider?(),
              let scene = window.windowScene,
              let endValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }

        let endFrame = window.convert(endValue.cgRectValue, from: window.screen.coordinateSpace)
        let rect = endFrame.intersection(window.bounds).integral
        // Only a genuine docked keyboard: bottom-anchored, full-width-ish and tall
        // enough — skips hardware-keyboard accessory bars and floating iPad keyboards.
        guard rect.height >= 100,
              rect.width >= window.bounds.width * 0.9,
              rect.maxY >= window.bounds.maxY - 2 else { return }

        let patch = activeCover?.visibleImage().flatMap { DotMatrixSnapshot.crop($0, to: rect) }
            ?? DotMatrixSnapshot.image(of: window, region: rect, afterScreenUpdates: false)
        guard let patch,
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: window) else {
            return
        }

        let slideDuration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? TimeInterval) ?? 0.25
        // A keyboard rising inside a `DotMatrixModal` present appears instantly (the
        // present is unanimated), long before the modal's own wipe plays. Deferring
        // the dissolve until `modalWipeDidStart()` makes the keyboard's dots run in
        // step with the modal's; the longer fallback covers a choreography that bails.
        let deferred = activeCover != nil
        current = Reveal(scene: scene, appWindow: window, overlay: overlay, frame: rect,
                         patch: patch, dissolveDuration: dissolveDuration,
                         deferToModalWipe: deferred,
                         fallbackDelay: deferred ? 1.0 : slideDuration + 0.1) {
            current = nil
        }
    }

    /// Called by `DotMatrixModal` the moment its wipe starts (or its choreography
    /// bails), releasing a reveal that armed during the unanimated present.
    static func modalWipeDidStart() {
        current?.beginDissolve()
    }

    /// Pay the process's one-time keyboard bring-up cost (~100ms+) now, off any tap
    /// path, so the first real keyboard — e.g. the reading list's "Save a Link"
    /// field — appears without stalling its modal's wipe. Call once, shortly after
    /// the window is up. The throwaway responder round-trip runs without animations,
    /// so the reveal machinery above ignores it.
    public static func prewarmKeyboard() {
        guard let window = windowProvider?() else { return }
        let field = UITextField(frame: .zero)
        window.addSubview(field)
        UIView.performWithoutAnimation {
            _ = field.becomeFirstResponder()
            _ = field.resignFirstResponder()
        }
        field.removeFromSuperview()
    }
}

/// One in-flight keyboard reveal: the above-keyboard patch window + the dissolve-out
/// overlay, torn down exactly once whatever order didShow / the fallback / a hide
/// arrive in.
private final class Reveal {

    private let cover: UIWindow
    private let overlay: RabbitHoleTransitionView
    private weak var appWindow: UIWindow?
    private let dissolveDuration: TimeInterval
    private let deferToModalWipe: Bool
    private let onFinish: () -> Void
    private var fallback: DispatchWorkItem?
    private var dissolving = false
    private var finished = false

    init(scene: UIWindowScene, appWindow: UIWindow, overlay: RabbitHoleTransitionView,
         frame: CGRect, patch: UIImage, dissolveDuration: TimeInterval,
         deferToModalWipe: Bool, fallbackDelay: TimeInterval,
         onFinish: @escaping () -> Void) {
        self.overlay = overlay
        self.appWindow = appWindow
        self.dissolveDuration = dissolveDuration
        self.deferToModalWipe = deferToModalWipe
        self.onFinish = onFinish

        // Above the keyboard's own window (≈ level 1e7); touch-transparent so the
        // rising keyboard is usable the moment it lands.
        cover = UIWindow(windowScene: scene)
        AppearanceSettings.apply(to: cover)
        cover.windowLevel = UIWindow.Level(rawValue: 20_000_000)
        cover.isUserInteractionEnabled = false
        cover.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        cover.rootViewController = root

        overlay.dissolvesOut = true
        overlay.style = DotMatrixTransitionStyleProvider.style(for: cover.traitCollection)
        overlay.direction = .bottomToTop   // the wave follows the keyboard's motion
        overlay.frame = frame
        overlay.autoresizingMask = []
        overlay.configure(before: patch, after: patch)   // after is unused dissolving out
        overlay.setProgress(0)
        overlay.isHidden = false
        root.view.addSubview(overlay)
        cover.isHidden = false

        // If keyboardDidShow never arrives (edge cases), dissolve anyway once the
        // system slide must have finished.
        let work = DispatchWorkItem { [weak self] in self?.beginDissolve() }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay, execute: work)
    }

    /// The keyboard has settled beneath the patch. Standalone reveals dissolve now;
    /// one armed during a modal present holds for `modalWipeDidStart()` (or the
    /// fallback) so its dots run in step with the modal's wipe.
    func keyboardDidShow() {
        guard !deferToModalWipe else { return }
        beginDissolve()
    }

    /// Dissolve the old pixels out, revealing the live keyboard.
    func beginDissolve() {
        guard !dissolving, !finished else { return }
        dissolving = true
        fallback?.cancel()
        overlay.animateProgress(to: 1, duration: dissolveDuration) { [weak self] in
            self?.finish()
        }
    }

    /// The keyboard is leaving mid-reveal — drop the patch instantly (its pre-keyboard
    /// pixels match what the departing keyboard uncovers anyway).
    func cancel() { finish() }

    private func finish() {
        guard !finished else { return }
        finished = true
        fallback?.cancel()
        DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: appWindow)
        cover.isHidden = true
        cover.rootViewController = nil
        onFinish()
    }
}
