import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// Settings → Editor / Read-along / Library / Appearance / About. Read-along
/// rows disappear on a device with neither gaze nor voice, rather than
/// showing disabled.
public final class WriterSettingsViewController: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case editor, readAlong, library, appearance, about }

    private enum EditorRow: Int, CaseIterable {
        case font, fontSize, lineWidth, focusMode, syntaxColouring, typewriter, authorship, palette
    }

    private enum ReadAlongRow { case gaze, voice, calibrate }
    private enum LibraryRow: Int, CaseIterable { case location, snapshotCount }
    private enum AppearanceRow: Int, CaseIterable { case interfaceStyle }
    private enum AboutRow: Int, CaseIterable { case version }

    private let environment: LibraryEnvironment
    private var readAlongRows: [ReadAlongRow] = []

    public init(environment: LibraryEnvironment) {
        self.environment = environment
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// The screen was unreachable — nothing constructed it (organiser #33).
    /// Presents a form sheet on a wide container (an iPad-sized secondary
    /// column counts as compact for this purpose, so this reads the actual
    /// presenter, not the device), pushes onto an existing nav stack on a
    /// compact one, and falls back to a full sheet with neither.
    public static func present(from presenter: UIViewController, environment: LibraryEnvironment) {
        let controller = WriterSettingsViewController(environment: environment)
        if LunaLayout.isWide(containerWidth: presenter.view.bounds.width) {
            let nav = UINavigationController(rootViewController: controller)
            nav.modalPresentationStyle = .formSheet
            presenter.present(nav, animated: true)
        } else if let navigationController = presenter.navigationController {
            navigationController.pushViewController(controller, animated: true)
        } else {
            presenter.present(UINavigationController(rootViewController: controller), animated: true)
        }
    }

    public override func viewDidLoad() {
        headerTitle = L10n.string("Common_settings")
        super.viewDidLoad()
        tableView.backgroundColor = LunaColors.background
        readAlongRows = Self.readAlongRows(for: environment.readAlongSettings)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange), name: WriterSettings.didChange, object: nil)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Recount on every appearance rather than on every settings change —
        // a snapshot can be added or restored elsewhere while this screen is
        // off screen (organiser #35).
        cachedSnapshotCount = nil
    }

    @objc private func settingsDidChange() { tableView.reloadData() }

    private static func readAlongRows(for handler: ReadAlongSettingsHandling?) -> [ReadAlongRow] {
        guard let handler else { return [] }
        var rows: [ReadAlongRow] = []
        if handler.gazeAvailable { rows.append(.gaze) }
        if handler.voiceAvailable { rows.append(.voice) }
        if !rows.isEmpty { rows.append(.calibrate) }
        return rows
    }

    private var visibleSections: [Section] {
        readAlongRows.isEmpty
            ? [.editor, .library, .appearance, .about]
            : Section.allCases
    }

    // MARK: - Table structure

    public override func numberOfSections(in tableView: UITableView) -> Int { visibleSections.count }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .editor: return EditorRow.allCases.count
        case .readAlong: return readAlongRows.count
        case .library: return LibraryRow.allCases.count
        case .appearance: return AppearanceRow.allCases.count
        case .about: return AboutRow.allCases.count
        }
    }

    public override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        switch visibleSections[section] {
        case .editor: return L10n.string("WriterLibrary_settings_editorSectionHeader")
        case .readAlong: return L10n.string("WriterLibrary_settings_readAlongSectionHeader")
        case .library: return L10n.string("WriterLibrary_settings_librarySectionHeader")
        case .appearance: return L10n.string("Settings_appearance_title")
        case .about: return L10n.string("WriterLibrary_settings_aboutSectionHeader")
        }
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch visibleSections[indexPath.section] {
        case .editor: return editorCell(for: EditorRow.allCases[indexPath.row])
        case .readAlong: return readAlongCell(for: readAlongRows[indexPath.row])
        case .library: return libraryCell(for: LibraryRow.allCases[indexPath.row])
        case .appearance: return appearanceCell()
        case .about: return aboutCell()
        }
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // Font / line width / focus mode select through their own `UIMenu`
        // button (organiser #12); the row itself does nothing on tap.
        switch visibleSections[indexPath.section] {
        case .readAlong:
            if readAlongRows[indexPath.row] == .calibrate {
                environment.readAlongSettings?.presentCalibration(from: self)
            }
        default: break
        }
    }

    // MARK: - Editor section

    private func editorCell(for row: EditorRow) -> UITableViewCell {
        switch row {
        case .font:
            return menuCell(
                title: L10n.string("WriterLibrary_settings_fontRow"),
                value: environment.settings.fontIdentifier?.capitalized
                    ?? L10n.string("Settings_readerFont_system"),
                menu: fontMenu())
        case .fontSize:
            return stepperCell(
                title: L10n.string("WriterLibrary_settings_fontSizeRow"),
                value: environment.settings.fontSize
            ) { [weak self] newValue in
                self?.environment.settings.fontSize = newValue
            }
        case .lineWidth:
            return menuCell(
                title: L10n.string("WriterLibrary_settings_lineWidthRow"),
                value: lineWidthDisplayName(environment.settings.lineWidth),
                menu: lineWidthMenu())
        case .focusMode:
            return menuCell(
                title: L10n.string("WriterLibrary_settings_focusModeRow"),
                value: focusModeDisplayName(environment.settings.focusMode),
                menu: focusModeMenu())
        case .syntaxColouring:
            return switchCell(
                title: L10n.string("WriterLibrary_settings_syntaxColouringRow"),
                isOn: environment.settings.syntaxColouring
            ) { [weak self] isOn in self?.environment.settings.syntaxColouring = isOn }
        case .typewriter:
            return switchCell(
                title: L10n.string("WriterLibrary_settings_typewriterRow"),
                isOn: environment.settings.typewriterScrolling
            ) { [weak self] isOn in self?.environment.settings.typewriterScrolling = isOn }
        case .authorship:
            return switchCell(
                title: L10n.string("WriterLibrary_settings_authorshipRow"),
                isOn: environment.settings.showAuthorship
            ) { [weak self] isOn in self?.environment.settings.showAuthorship = isOn }
        case .palette:
            return menuCell(
                title: L10n.string("WriterLibrary_settings_paletteRow"),
                value: paletteTriggerDisplayName(environment.settings.paletteTrigger),
                menu: paletteTriggerMenu())
        }
    }

    private func paletteTriggerDisplayName(_ value: PaletteTrigger) -> String {
        switch value {
        case .doubleSpace: return L10n.string("WriterLibrary_settings_paletteDoubleSpace")
        case .atSign: return L10n.string("WriterLibrary_settings_paletteAtSign")
        }
    }

    private func paletteTriggerMenu() -> UIMenu {
        UIMenu(children: PaletteTrigger.allCases.map { value in
            UIAction(
                title: paletteTriggerDisplayName(value),
                state: value == environment.settings.paletteTrigger ? .on : .off
            ) { [weak self] _ in
                self?.environment.settings.paletteTrigger = value
                self?.tableView.reloadData()
            }
        })
    }

    private func lineWidthDisplayName(_ value: EditorLineWidth) -> String {
        switch value {
        case .narrow: return L10n.string("WriterLibrary_settings_lineWidthNarrow")
        case .medium: return L10n.string("WriterLibrary_settings_lineWidthMedium")
        case .wide: return L10n.string("WriterLibrary_settings_lineWidthWide")
        }
    }

    private func focusModeDisplayName(_ value: FocusMode) -> String {
        switch value {
        case .off: return L10n.string("Common_off")
        case .sentence: return L10n.string("WriterLibrary_settings_focusModeSentence")
        case .paragraph: return L10n.string("WriterLibrary_settings_focusModeParagraph")
        }
    }

    // A `UIMenu` on the row's own button, never an action sheet — an action
    // sheet with no popover anchor crashes on iPad (organiser #12).
    private func fontMenu() -> UIMenu {
        UIMenu(children: ReaderFont.allCases.map { font in
            UIAction(
                title: font.displayName,
                state: font.rawValue == environment.settings.fontIdentifier ? .on : .off
            ) { [weak self] _ in
                self?.environment.settings.fontIdentifier = font.rawValue
                self?.tableView.reloadData()
            }
        })
    }

    private func lineWidthMenu() -> UIMenu {
        UIMenu(children: EditorLineWidth.allCases.map { value in
            UIAction(
                title: lineWidthDisplayName(value),
                state: value == environment.settings.lineWidth ? .on : .off
            ) { [weak self] _ in
                self?.environment.settings.lineWidth = value
                self?.tableView.reloadData()
            }
        })
    }

    private func focusModeMenu() -> UIMenu {
        UIMenu(children: FocusMode.allCases.map { value in
            UIAction(
                title: focusModeDisplayName(value),
                state: value == environment.settings.focusMode ? .on : .off
            ) { [weak self] _ in
                self?.environment.settings.focusMode = value
                self?.tableView.reloadData()
            }
        })
    }

    // MARK: - Read-along section

    private func readAlongCell(for row: ReadAlongRow) -> UITableViewCell {
        guard let handler = environment.readAlongSettings else { return UITableViewCell() }
        switch row {
        case .gaze:
            return switchCell(
                title: L10n.string("WriterLibrary_settings_gazeRow"), isOn: environment.settings.gazeEnabled
            ) { [weak self] isOn in self?.environment.settings.gazeEnabled = isOn }
        case .voice:
            return switchCell(
                title: L10n.string("WriterLibrary_settings_voiceRow"), isOn: environment.settings.voiceEnabled
            ) { [weak self] isOn in self?.environment.settings.voiceEnabled = isOn }
        case .calibrate:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = L10n.string("WriterLibrary_settings_calibrateRow")
            cell.detailTextLabel?.text = handler.lastCalibrationGrade
            cell.detailTextLabel?.textColor = LunaColors.secondaryText
            cell.accessoryType = .disclosureIndicator
            cell.backgroundColor = LunaColors.secondaryBackground
            return cell
        }
    }

    // MARK: - Library section

    private func libraryCell(for row: LibraryRow) -> UITableViewCell {
        switch row {
        case .location:
            return valueCell(
                title: L10n.string("WriterLibrary_settings_locationRow"),
                value: environment.libraryRootPath == nil
                    ? L10n.string("WriterLibrary_settings_locationUnknown")
                    : L10n.string("WriterLibrary_settings_locationValue"))
        case .snapshotCount:
            return valueCell(
                title: L10n.string("WriterLibrary_settings_snapshotCountRow"),
                value: "\(totalSnapshotCount())")
        }
    }

    /// Every kept snapshot across every non-trashed sheet. Cached for the
    /// screen's appearance: `settingsDidChange` reloads the whole table on
    /// any editor/read-along toggle, and re-querying every sheet's snapshots
    /// on each of those was wasted work for a row nothing on this screen
    /// changes (organiser #35).
    private var cachedSnapshotCount: Int?

    private func totalSnapshotCount() -> Int {
        if let cachedSnapshotCount { return cachedSnapshotCount }
        let documents = (try? environment.library.documents(matching: FilterPredicate(), scope: nil)) ?? []
        let count = documents.reduce(0) { total, document in
            total + ((try? environment.snapshots.snapshots(for: document.id).count) ?? 0)
        }
        cachedSnapshotCount = count
        return count
    }

    // MARK: - Appearance / About

    /// The same System / Light / Dark chooser the other Luna apps show in
    /// Settings → Appearance, reached here because that screen lives in the
    /// app target and this module cannot import it (organiser #34).
    private func appearanceCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = LunaColors.secondaryBackground
        let control = UISegmentedControl(
            items: AppearanceSettings.InterfaceStyle.allCases.map(\.displayName))
        control.selectedSegmentIndex =
            AppearanceSettings.InterfaceStyle.allCases.firstIndex(of: AppearanceSettings.interfaceStyle) ?? 0
        control.addTarget(self, action: #selector(interfaceStyleChanged(_:)), for: .valueChanged)
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: cell.contentView.topAnchor, constant: 8),
            control.bottomAnchor.constraint(lessThanOrEqualTo: cell.contentView.bottomAnchor, constant: -8),
        ])
        return cell
    }

    @objc private func interfaceStyleChanged(_ control: UISegmentedControl) {
        let styles = AppearanceSettings.InterfaceStyle.allCases
        AppearanceSettings.interfaceStyle = styles[max(0, min(control.selectedSegmentIndex, styles.count - 1))]
        if let window = view.window { AppearanceSettings.apply(to: window) }
    }

    private func aboutCell() -> UITableViewCell {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return valueCell(title: L10n.string("WriterLibrary_settings_versionRow"), value: version)
    }

    // MARK: - Row builders

    private func valueCell(title: String, value: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = value
        cell.detailTextLabel?.textColor = LunaColors.secondaryText
        cell.backgroundColor = LunaColors.secondaryBackground
        return cell
    }

    /// A row whose value is set from a `UIMenu` on its own trailing button —
    /// never a presented action sheet, which needs a popover anchor UIKit
    /// does not supply here and crashes on iPad (organiser #12).
    private func menuCell(title: String, value: String, menu: UIMenu) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.backgroundColor = LunaColors.secondaryBackground
        cell.selectionStyle = .none
        var configuration = UIButton.Configuration.plain()
        configuration.title = value
        configuration.image = UIImage(systemName: "chevron.up.chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.baseForegroundColor = LunaColors.secondaryText
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.sizeToFit()
        cell.accessoryView = button
        return cell
    }

    private func switchCell(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.backgroundColor = LunaColors.secondaryBackground
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { _ in onChange(toggle.isOn) }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private func stepperCell(title: String, value: Double, onChange: @escaping (Double) -> Void) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = "\(Int(value))"
        cell.backgroundColor = LunaColors.secondaryBackground
        cell.selectionStyle = .none
        let stepper = UIStepper()
        stepper.minimumValue = 12
        stepper.maximumValue = 32
        stepper.value = value
        stepper.addAction(UIAction { _ in
            onChange(stepper.value)
            cell.detailTextLabel?.text = "\(Int(stepper.value))"
        }, for: .valueChanged)
        cell.accessoryView = stepper
        return cell
    }
}
