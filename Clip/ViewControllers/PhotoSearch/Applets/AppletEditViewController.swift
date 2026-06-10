//
//  AppletEditViewController.swift
//  clipper
//

import UIKit

/// Create or edit one applet. New applets prompt for a "contains" query and, on
/// save, backfill against the existing photo index (with progress). Existing
/// applets allow editing the name + notification toggle (the query is fixed).
final class AppletEditViewController: UIViewController {

    private let context: PhotoSearchContext
    private let existingApplet: Applet?
    private lazy var manager = AppletManager(context: context)

    /// Invoked after a successful create/update/delete so the list can refresh.
    var onChange: (() -> Void)?

    private let queryField = UITextField()
    private let nameField = UITextField()
    private let notifySwitch = UISwitch()

    private let overlay = UIView()
    private let overlayLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)

    private var isNew: Bool { existingApplet == nil }

    init(context: PhotoSearchContext, applet: Applet?) {
        self.context = context
        self.existingApplet = applet
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "New Applet" : "Edit Applet"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(save)
        )
        configureForm()
        configureOverlay()
    }

    private func configureForm() {
        queryField.placeholder = "What to look for, e.g. a dog"
        queryField.borderStyle = .roundedRect
        queryField.autocapitalizationType = .none
        queryField.text = existingApplet?.query
        queryField.isEnabled = isNew // query is fixed once created (it seeds the count)

        nameField.placeholder = "Name (optional)"
        nameField.borderStyle = .roundedRect
        nameField.text = existingApplet?.name

        notifySwitch.isOn = existingApplet?.notifyOnCapture ?? false
        let notifyRow = UIStackView(arrangedSubviews: [makeLabel("Notify on each capture"), notifySwitch])
        notifyRow.axis = .horizontal
        notifyRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            makeLabel("Match"), queryField,
            makeLabel("Name"), nameField,
            notifyRow,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(20, after: queryField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        if !isNew {
            let delete = UIButton(type: .system)
            delete.setTitle("Delete Applet", for: .normal)
            delete.setTitleColor(.systemRed, for: .normal)
            delete.addTarget(self, action: #selector(deleteApplet), for: .touchUpInside)
            delete.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(delete)
            NSLayoutConstraint.activate([
                delete.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 40),
                delete.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ])
        }
    }

    private func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        return label
    }

    private func configureOverlay() {
        overlay.backgroundColor = .systemBackground.withAlphaComponent(0.9)
        overlay.isHidden = true
        overlay.translatesAutoresizingMaskIntoConstraints = false

        overlayLabel.text = "Scanning your photos…"
        overlayLabel.textAlignment = .center
        progressView.progress = 0

        let box = UIStackView(arrangedSubviews: [overlayLabel, progressView])
        box.axis = .vertical
        box.spacing = 12
        box.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(box)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            box.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            box.widthAnchor.constraint(equalTo: overlay.widthAnchor, multiplier: 0.7),
        ])
    }

    // MARK: - Actions

    @objc private func save() {
        let query = (queryField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = existingApplet {
            var updated = existing
            updated.name = name.isEmpty ? existing.query : name
            updated.notifyOnCapture = notifySwitch.isOn
            Task {
                try? await manager.update(updated)
                onChange?()
                navigationController?.popViewController(animated: true)
            }
            return
        }

        guard !query.isEmpty else {
            presentAlert(title: "Add a description", message: "Tell Pouch what to look for, like “a dog”.")
            return
        }

        setOverlay(visible: true, progress: 0)
        let notify = notifySwitch.isOn
        Task {
            do {
                _ = try await manager.create(
                    query: query, name: name, notifyOnCapture: notify,
                    onProgress: { [weak self] progress in
                        self?.progressView.setProgress(Float(progress), animated: true)
                    }
                )
                onChange?()
                navigationController?.popViewController(animated: true)
            } catch {
                setOverlay(visible: false, progress: 0)
                presentAlert(title: "Couldn't create applet", message: error.localizedDescription)
            }
        }
    }

    @objc private func deleteApplet() {
        guard let existing = existingApplet else { return }
        manager.delete(existing)
        onChange?()
        navigationController?.popViewController(animated: true)
    }

    private func setOverlay(visible: Bool, progress: Float) {
        overlay.isHidden = !visible
        progressView.setProgress(progress, animated: false)
        navigationItem.rightBarButtonItem?.isEnabled = !visible
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
