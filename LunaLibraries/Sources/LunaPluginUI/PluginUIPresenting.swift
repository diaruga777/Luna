//
//  PluginUIPresenting.swift
//  LunaPluginUI
//
//  The `luna.ui` witness (plugin-platform.md §6.12). The runtime's bridge —
//  installed by a registry that is not this module's responsibility — calls
//  through `PluginUIComposition.presenter`; this file only owns the UIKit
//  implementation and the static that holds it.
//

import UIKit

/// The keyboard a `luna.ui.prompt` call asked for.
public enum PluginPromptKeyboard: String, Sendable {
    case defaultKeyboard, email, url, number
}

/// One row of a `luna.ui.choose` menu.
public struct PluginUIChoiceOption: Equatable, Sendable {
    public let id: String
    public let label: String
    public let detail: String?
    public init(id: String, label: String, detail: String? = nil) {
        self.id = id; self.label = label; self.detail = detail
    }
}

/// One item of a `luna.ui.shareSheet` call.
public enum PluginShareItem: Sendable {
    case fileURL(URL)
    case url(URL)
    case text(String)
}

/// Presents UI on the app's behalf from wherever a plugin's `ui` capability is
/// invoked. Only ever asked of the app process — an extension or a background
/// call rejects before reaching this witness (§6.12).
@MainActor
public protocol PluginUIPresenting: AnyObject {
    func prompt(
        title: String, message: String?, placeholder: String?, keyboard: PluginPromptKeyboard,
        secure: Bool, defaultValue: String?
    ) async -> String?
    func confirm(
        title: String, message: String?, ok: String?, cancel: String?, destructive: Bool
    ) async -> Bool
    func choose(title: String, options: [PluginUIChoiceOption]) async -> String?
    func toast(_ message: String) async
    func shareSheet(items: [PluginShareItem]) async
}

/// The UIKit answer: alerts and an action sheet presented over the frontmost
/// view controller of the foreground scene's key window.
@MainActor
public final class PluginUIPresenter: PluginUIPresenting {

    public init() {}

    public func prompt(
        title: String, message: String?, placeholder: String?, keyboard: PluginPromptKeyboard,
        secure: Bool, defaultValue: String?
    ) async -> String? {
        guard let presenter = Self.topViewController() else { return nil }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = placeholder
                field.text = defaultValue
                field.isSecureTextEntry = secure
                switch keyboard {
                case .defaultKeyboard: field.keyboardType = .default
                case .email: field.keyboardType = .emailAddress
                case .url: field.keyboardType = .URL
                case .number: field.keyboardType = .numberPad
                }
            }
            alert.addAction(UIAlertAction(title: PluginUIStrings.cancel, style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: PluginUIStrings.ok, style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }
    }

    public func confirm(
        title: String, message: String?, ok: String?, cancel: String?, destructive: Bool
    ) async -> Bool {
        guard let presenter = Self.topViewController() else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: cancel ?? PluginUIStrings.cancel, style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(
                UIAlertAction(
                    title: ok ?? PluginUIStrings.ok,
                    style: destructive ? .destructive : .default
                ) { _ in
                    continuation.resume(returning: true)
                })
            presenter.present(alert, animated: true)
        }
    }

    public func choose(title: String, options: [PluginUIChoiceOption]) async -> String? {
        guard let presenter = Self.topViewController() else { return nil }
        return await withCheckedContinuation { continuation in
            let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
            for option in options {
                sheet.addAction(UIAlertAction(title: option.label, style: .default) { _ in
                    continuation.resume(returning: option.id)
                })
            }
            sheet.addAction(UIAlertAction(title: PluginUIStrings.cancel, style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            Self.anchorPopover(sheet, to: presenter.view)
            presenter.present(sheet, animated: true)
        }
    }

    public func toast(_ message: String) async {
        guard let window = Self.foregroundWindow() else { return }
        let label = PluginToastLabel(text: message)
        window.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            label.bottomAnchor.constraint(
                equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            label.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -48),
        ])
        await label.showAndDismiss()
    }

    public func shareSheet(items: [PluginShareItem]) async {
        guard let presenter = Self.topViewController() else { return }
        let activityItems: [Any] = items.map { item in
            switch item {
            case .fileURL(let url): return url
            case .url(let url): return url
            case .text(let text): return text
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let controller = UIActivityViewController(
                activityItems: activityItems, applicationActivities: nil)
            controller.completionWithItemsHandler = { _, _, _, _ in continuation.resume() }
            Self.anchorPopover(controller, to: presenter.view)
            presenter.present(controller, animated: true)
        }
    }

    private static func foregroundWindow() -> UIWindow? { PluginTopPresenter.window() }

    private static func topViewController() -> UIViewController? { PluginTopPresenter.current() }

    /// iPad presents an action sheet or activity view as a popover, which
    /// crashes at present time with no anchor. A plugin call names no
    /// on-screen control to anchor to, so both center on the presenting
    /// view with no arrow, matching `PluginImportCoordinator.begin`.
    private static func anchorPopover(_ controller: UIViewController, to view: UIView) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = view
        popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
}

/// `PluginUIPresenter`'s own copy, kept out of `L10n` on purpose: "OK" and
/// "Cancel" here are the fallback shown when a plugin's own `ok`/`cancel`
/// strings are absent, not a Luna-authored sentence.
private enum PluginUIStrings {
    static let ok = "OK"
    static let cancel = "Cancel"
}

/// A transient message, faded in and out over whatever is on screen.
private final class PluginToastLabel: UILabel {
    init(text: String) {
        super.init(frame: .zero)
        self.text = text
        numberOfLines = 2
        textAlignment = .center
        font = .preferredFont(forTextStyle: .subheadline)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.85)
        layer.cornerRadius = 12
        clipsToBounds = true
        alpha = 0
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @MainActor
    func showAndDismiss() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UIView.animate(withDuration: 0.2, animations: { self.alpha = 1 }) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    UIView.animate(
                        withDuration: 0.2, animations: { self.alpha = 0 },
                        completion: { _ in
                            self.removeFromSuperview()
                            continuation.resume()
                        })
                }
            }
        }
    }
}

/// Holds the `luna.ui` witness. The runtime's bridge registry (not this
/// module) reads `PluginUIComposition.presenter` when a plugin calls into
/// `luna.ui`; the orchestrator wires that read once the registry exists.
public enum PluginUIComposition {
    @MainActor public private(set) static var presenter: PluginUIPresenting?

    @MainActor
    public static func install(_ presenter: PluginUIPresenting? = nil) {
        self.presenter = presenter ?? PluginUIPresenter()
    }
}
