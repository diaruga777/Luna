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
        case font, fontSize, lineWidth, focusMode, syntaxColouring, typewriter, authorship
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

    public override func viewDidLoad() {
        headerTitle = L10n.string("Common_settings")
        super.viewDidLoad()
        tableView.backgroundColor = LunaColors.background
        readAlongRows = Self.readAlongRows(for: environment.readAlongSettings)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange), name: WriterSettings.didChange, object: nil)
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
        switch visibleSections[indexPath.section] {
        case .editor:
            switch EditorRow.allCases[indexPath.row] {
            case .font: presentFontMenu()
            case .lineWidth: presentLineWidthMenu()
            case .focusMode: presentFocusModeMenu()
            default: break
            }
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
            return valueCell(
                title: L10n.string("WriterLibrary_settings_fontRow"),
                value: environment.settings.fontIdentifier?.capitalized
                    ?? L10n.string("Settings_readerFont_system"))
        case .fontSize:
            return stepperCell(
                title: L10n.string("WriterLibrary_settings_fontSizeRow"),
                value: environment.settings.fontSize
            ) { [weak self] newValue in
                self?.environment.settings.fontSize = newValue
            }
        case .lineWidth:
            return valueCell(
                title: L10n.string("WriterLibrary_settings_lineWidthRow"),
                value: lineWidthDisplayName(environment.settings.lineWidth))
        case .focusMode:
            return valueCell(
                title: L10n.string("WriterLibrary_settings_focusModeRow"),
                value: focusModeDisplayName(environment.settings.focusMode))
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
        }
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

    private func presentFontMenu() {
        let alert = UIAlertController(title: L10n.string("WriterLibrary_settings_fontRow"), message: nil, preferredStyle: .actionSheet)
        for font in ReaderFont.allCases {
            alert.addAction(UIAlertAction(title: font.displayName, style: .default) { [weak self] _ in
                self?.environment.settings.fontIdentifier = font.rawValue
                self?.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func presentLineWidthMenu() {
        let alert = UIAlertController(title: L10n.string("WriterLibrary_settings_lineWidthRow"), message: nil, preferredStyle: .actionSheet)
        for value in EditorLineWidth.allCases {
            alert.addAction(UIAlertAction(title: lineWidthDisplayName(value), style: .default) { [weak self] _ in
                self?.environment.settings.lineWidth = value
                self?.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func presentFocusModeMenu() {
        let alert = UIAlertController(title: L10n.string("WriterLibrary_settings_focusModeRow"), message: nil, preferredStyle: .actionSheet)
        for value in FocusMode.allCases {
            alert.addAction(UIAlertAction(title: focusModeDisplayName(value), style: .default) { [weak self] _ in
                self?.environment.settings.focusMode = value
                self?.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        present(alert, animated: true)
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
                value: environment.libraryRootPath ?? L10n.string("WriterLibrary_settings_locationUnknown"))
        case .snapshotCount:
            return valueCell(
                title: L10n.string("WriterLibrary_settings_snapshotCountRow"),
                value: "\(totalSnapshotCount())")
        }
    }

    /// Every kept snapshot across every non-trashed sheet.
    private func totalSnapshotCount() -> Int {
        let documents = (try? environment.library.documents(matching: FilterPredicate(), scope: nil)) ?? []
        return documents.reduce(0) { total, document in
            total + ((try? environment.snapshots.snapshots(for: document.id).count) ?? 0)
        }
    }

    // MARK: - Appearance / About

    private func appearanceCell() -> UITableViewCell {
        valueCell(
            title: L10n.string("Settings_appearance_title"),
            value: AppearanceSettings.interfaceStyle.displayName)
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
