//
//  EditorAccessoryBar.swift
//  LunaWriterEditor
//

import UIKit
import GameController
import LunaDesignSystem
import LunaModels

/// What the bar's buttons ask for.
public enum EditorAccessoryAction: String, CaseIterable {
    case heading, bold, italic, list, task, quote, link, code, mention, focus, statistics

    var symbolName: String {
        switch self {
        case .heading: return "number"
        case .bold: return "bold"
        case .italic: return "italic"
        case .list: return "list.bullet"
        case .task: return "checklist"
        case .quote: return "text.quote"
        case .link: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .mention: return "at"
        case .focus: return "scope"
        case .statistics: return "chart.bar"
        }
    }

    var accessibilityKey: String {
        "WriterEditor_accessory_\(rawValue)"
    }
}

public protocol EditorAccessoryBarDelegate: AnyObject {
    func editorAccessoryBar(_ bar: EditorAccessoryBar, didSelect action: EditorAccessoryAction)
}

/// The row of Markdown commands above the keyboard.
///
/// A hardware keyboard makes it dead weight: everything on it has a shortcut,
/// so the bar hides itself when one is attached.
public final class EditorAccessoryBar: UIView {

    public static let height: CGFloat = 48

    public weak var delegate: EditorAccessoryBarDelegate?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var buttons: [EditorAccessoryAction: UIButton] = [:]

    public init(actions: [EditorAccessoryAction] = EditorAccessoryAction.allCases) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height))
        build(actions)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardChanged),
            name: NSNotification.Name.GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardChanged),
            name: NSNotification.Name.GCKeyboardDidDisconnect, object: nil)
        updateHardwareKeyboardVisibility()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    private func build(_ actions: [EditorAccessoryAction]) {
        backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        for action in actions {
            let button = UIButton(type: .system)
            button.configuration = GlassStyle.circularButtonConfiguration(symbol: action.symbolName, padding: 8)
            button.tintColor = LunaColors.primaryText
            button.accessibilityLabel = L10n.string(action.accessibilityKey)
            button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            button.tag = actions.firstIndex(of: action) ?? 0
            buttons[action] = button
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    /// Marks the Focus button while Focus mode is on.
    public func setFocusActive(_ isActive: Bool) {
        buttons[.focus]?.tintColor = isActive ? EditorTheme.caret : LunaColors.primaryText
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        guard let action = buttons.first(where: { $0.value === sender })?.key else { return }
        delegate?.editorAccessoryBar(self, didSelect: action)
    }

    @objc private func keyboardChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateHardwareKeyboardVisibility()
        }
    }

    /// True when a hardware keyboard is attached, which is when the bar goes.
    public static var hasHardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

    public func updateHardwareKeyboardVisibility() {
        let hide = Self.hasHardwareKeyboard && traitCollection.userInterfaceIdiom == .pad
        isHidden = hide
    }
}
