import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels

/// The Ulysses organiser's root: groups in the primary column, that group's
/// sheets in the supplementary column, and the open sheet's editor in the
/// secondary column. `preferredDisplayMode` follows `LunaLayout.isWide`
/// rather than the size class UIKit would otherwise pick.
public final class LibraryRootViewController: UISplitViewController {

    private let environment: LibraryEnvironment
    private let groupsViewController: GroupsViewController
    private let sheetsViewController: SheetsViewController

    public init(environment: LibraryEnvironment) {
        self.environment = environment
        self.groupsViewController = GroupsViewController(
            library: environment.library, notes: environment.notes)
        self.sheetsViewController = SheetsViewController(
            library: environment.library, notes: environment.notes)
        super.init(style: .tripleColumn)
        groupsViewController.selectionDelegate = self
        sheetsViewController.selectionDelegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        setViewController(UINavigationController(rootViewController: groupsViewController), for: .primary)
        setViewController(UINavigationController(rootViewController: sheetsViewController), for: .supplementary)
        setViewController(Self.emptySecondaryPlaceholder(), for: .secondary)
        updatePreferredDisplayMode()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredDisplayMode()
    }

    private func updatePreferredDisplayMode() {
        preferredDisplayMode = LunaLayout.isWide(containerWidth: view.bounds.width)
            ? .twoBesideSecondary : .oneBesideSecondary
    }

    private static func emptySecondaryPlaceholder() -> UIViewController {
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = LunaColors.background
        let label = UILabel()
        label.text = L10n.string("WriterLibrary_editor_emptySelection")
        label.textColor = LunaColors.secondaryText
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        placeholder.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: placeholder.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: placeholder.view.centerYAnchor),
        ])
        return placeholder
    }
}

extension LibraryRootViewController: GroupsSelectionDelegate {
    public func groupsViewController(_ controller: GroupsViewController, didSelect selection: LibrarySelection) {
        sheetsViewController.select(selection)
        show(.supplementary)
    }
}

extension LibraryRootViewController: SheetsSelectionDelegate {
    public func sheetsViewController(_ controller: SheetsViewController, didSelect document: WriterDocument) {
        show(document: document)
    }

    /// Opens a sheet in the detail column. Deep links and intents arrive here
    /// as well as the sheets list.
    public func show(document: WriterDocument) {
        let editorContainer = EditorContainerViewController(environment: environment, document: document)
        setViewController(editorContainer, for: .secondary)
        show(.secondary)
    }
}
