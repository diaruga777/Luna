import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// Names a filter and sets its predicate: text to search for, favourites
/// only, a modified-within window, and the keywords every match must carry.
/// Presented for a new filter and for editing one from the sidebar.
public final class FilterEditorViewController: UIViewController {

    /// Told when the filter was saved, with the stored value.
    public var onSave: ((WriterFilter) -> Void)?

    private let library: WriterLibraryStoring
    private var filter: WriterFilter

    private let nameField = UITextField()
    private let searchField = UITextField()
    private let favoritesSwitch = UISwitch()
    private let modifiedControl: UISegmentedControl
    private let keywordsField = UITextField()

    /// The window each "Modified within" segment stands for; nil is any time.
    static let modifiedWindows: [TimeInterval?] = [nil, 86_400, 7 * 86_400, 30 * 86_400]

    public init(library: WriterLibraryStoring, filter: WriterFilter) {
        self.library = library
        self.filter = filter
        self.modifiedControl = UISegmentedControl(items: [
            L10n.string("WriterLibrary_filter_modifiedAny"),
            L10n.string("WriterLibrary_filter_modifiedDay"),
            L10n.string("WriterLibrary_filter_modifiedWeek"),
            L10n.string("WriterLibrary_filter_modifiedMonth"),
        ])
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_filter_title")
        view.backgroundColor = LunaColors.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_cancel"), style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_save"), style: .done, target: self, action: #selector(saveTapped))

        configure(nameField, placeholder: L10n.string("WriterLibrary_filter_namePlaceholder"), text: filter.name)
        nameField.autocapitalizationType = .words
        configure(
            searchField, placeholder: L10n.string("WriterLibrary_filter_searchPlaceholder"),
            text: filter.predicate.searchText ?? "")
        configure(
            keywordsField, placeholder: L10n.string("WriterLibrary_filter_keywordsPlaceholder"),
            text: filter.predicate.keywordsAll.joined(separator: ", "))
        keywordsField.autocapitalizationType = .none

        favoritesSwitch.isOn = filter.predicate.favoritesOnly
        let favoritesLabel = UILabel()
        favoritesLabel.text = L10n.string("WriterLibrary_filter_favoritesOnly")
        favoritesLabel.textColor = LunaColors.primaryText
        favoritesLabel.font = .preferredFont(forTextStyle: .body)
        let favoritesRow = UIStackView(arrangedSubviews: [favoritesLabel, favoritesSwitch])
        favoritesRow.axis = .horizontal

        let modifiedLabel = UILabel()
        modifiedLabel.text = L10n.string("WriterLibrary_filter_modifiedWithin")
        modifiedLabel.textColor = LunaColors.secondaryText
        modifiedLabel.font = .preferredFont(forTextStyle: .footnote)
        modifiedControl.selectedSegmentIndex =
            Self.modifiedWindows.firstIndex(of: filter.predicate.modifiedWithin) ?? 0

        let stack = UIStackView(arrangedSubviews: [
            nameField, searchField, favoritesRow, modifiedLabel, modifiedControl, keywordsField,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(6, after: modifiedLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if nameField.text?.isEmpty ?? true { nameField.becomeFirstResponder() }
    }

    private func configure(_ field: UITextField, placeholder: String, text: String) {
        field.borderStyle = .roundedRect
        field.backgroundColor = LunaColors.secondaryBackground
        field.textColor = LunaColors.primaryText
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        field.text = text
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func saveTapped() {
        guard save() else { return }
        dismiss(animated: true)
    }

    /// Reads the form into the filter and stores it. Exposed for tests.
    @discardableResult
    public func save() -> Bool {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        filter.name = name.isEmpty ? L10n.string("WriterLibrary_groups_newFilterDefaultName") : name
        let search = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        filter.predicate.searchText = search.isEmpty ? nil : search
        filter.predicate.favoritesOnly = favoritesSwitch.isOn
        let index = modifiedControl.selectedSegmentIndex
        filter.predicate.modifiedWithin = Self.modifiedWindows.indices.contains(index) ? Self.modifiedWindows[index] : nil
        filter.predicate.keywordsAll = (keywordsField.text ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard (try? library.save(filter)) != nil else { return false }
        onSave?(filter)
        return true
    }
}
