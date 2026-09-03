import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// Sets or clears a sheet's writing goal: unit, mode, and a numeric target.
/// The ring at the top previews progress against the value on screen.
public final class GoalEditorViewController: UIViewController {

    private let library: WriterLibraryStoring
    private var document: WriterDocument
    private var unit: WritingGoal.Unit
    private var mode: WritingGoal.Mode
    private var target: Int

    private let goalBar = MoonHorizonProgressBar()
    private let unitControl: UISegmentedControl
    private let modeControl: UISegmentedControl
    private let targetField = UITextField()

    public init(library: WriterLibraryStoring, document: WriterDocument) {
        self.library = library
        self.document = document
        self.unit = document.goal?.unit ?? .words
        self.mode = document.goal?.mode ?? .atLeast
        self.target = document.goal?.target ?? 500
        self.unitControl = UISegmentedControl(items: [
            L10n.string("WriterLibrary_goal_unitWords"),
            L10n.string("WriterLibrary_goal_unitCharacters"),
            L10n.string("WriterLibrary_goal_unitSentences"),
            L10n.string("WriterLibrary_goal_unitReadingMinutes"),
        ])
        self.modeControl = UISegmentedControl(items: [
            L10n.string("WriterLibrary_goal_modeAtLeast"),
            L10n.string("WriterLibrary_goal_modeAtMost"),
            L10n.string("WriterLibrary_goal_modeAbout"),
        ])
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_goal_title")
        view.backgroundColor = LunaColors.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_cancel"), style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_save"), style: .done, target: self, action: #selector(saveTapped))

        unitControl.selectedSegmentIndex = Self.unitIndex(unit)
        modeControl.selectedSegmentIndex = Self.modeIndex(mode)
        unitControl.addTarget(self, action: #selector(valuesChanged), for: .valueChanged)
        modeControl.addTarget(self, action: #selector(valuesChanged), for: .valueChanged)

        targetField.text = "\(target)"
        targetField.keyboardType = .numberPad
        targetField.textColor = LunaColors.primaryText
        targetField.addTarget(self, action: #selector(targetFieldChanged), for: .editingChanged)

        goalBar.showsActivityPulse = false

        let stack = UIStackView(arrangedSubviews: [goalBar, unitControl, modeControl, targetField])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            goalBar.heightAnchor.constraint(equalToConstant: 10),
        ])
        updateGoalBar()
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func valuesChanged() {
        unit = Self.unit(at: unitControl.selectedSegmentIndex)
        mode = Self.mode(at: modeControl.selectedSegmentIndex)
        updateGoalBar()
    }

    @objc private func targetFieldChanged() {
        target = Int(targetField.text ?? "") ?? 0
        updateGoalBar()
    }

    private func updateGoalBar() {
        let goal = WritingGoal(unit: unit, target: max(1, target), mode: mode)
        goalBar.setProgress(SheetCell.progress(for: document, goal: goal), animated: true)
    }

    @objc private func saveTapped() {
        _ = save()
        dismiss(animated: true)
    }

    @discardableResult
    public func save() -> Bool {
        document.goal = WritingGoal(unit: unit, target: max(1, target), mode: mode)
        guard (try? library.update(document)) != nil else { return false }
        return true
    }

    @discardableResult
    public func clearGoal() -> Bool {
        document.goal = nil
        guard (try? library.update(document)) != nil else { return false }
        return true
    }

    private static func unitIndex(_ unit: WritingGoal.Unit) -> Int {
        switch unit {
        case .words: return 0
        case .characters: return 1
        case .sentences: return 2
        case .readingMinutes: return 3
        }
    }

    private static func unit(at index: Int) -> WritingGoal.Unit {
        [.words, .characters, .sentences, .readingMinutes][index]
    }

    private static func modeIndex(_ mode: WritingGoal.Mode) -> Int {
        switch mode {
        case .atLeast: return 0
        case .atMost: return 1
        case .about: return 2
        }
    }

    private static func mode(at index: Int) -> WritingGoal.Mode {
        [.atLeast, .atMost, .about][index]
    }
}
