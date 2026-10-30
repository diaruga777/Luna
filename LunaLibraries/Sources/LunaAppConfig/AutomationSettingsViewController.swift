#if canImport(UIKit)
import UIKit

/// Shared settings presentation; preferences and notification permission remain per app.
@MainActor public final class AutomationSettingsViewController: UITableViewController {
    private let automation: AppAutomation
    public init(app: AutomationApp) {
        automation = AppAutomation(app: app)
        super.init(style: .insetGrouped)
        title = "Automations"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() { super.viewDidLoad(); tableView.register(UITableViewCell.self, forCellReuseIdentifier: "toggle") }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { AutomationChangeOperation.allCases.count }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Choose which changes can trigger a Shortcut. Notification delivery follows your system settings."
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "toggle", for: indexPath)
        let operation = AutomationChangeOperation.allCases[indexPath.row]
        var config = cell.defaultContentConfiguration(); config.text = operation.title; cell.contentConfiguration = config
        let toggle = UISwitch(); toggle.isOn = automation.notificationsEnabled(for: operation.rawValue)
        toggle.accessibilityIdentifier = "automation.change-notifications.\(operation.rawValue)"
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            let enabled = toggle.isOn; toggle.isEnabled = false
            Task { @MainActor in
                defer { toggle.isEnabled = true; toggle.isOn = self.automation.notificationsEnabled(for: operation.rawValue) }
                do { try await self.automation.setNotificationsEnabled(enabled, for: operation) }
                catch {
                    let alert = UIAlertController(title: "Couldn’t Change Notifications", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default)); self.present(alert, animated: true)
                }
            }
        }, for: .valueChanged)
        cell.accessoryView = toggle; cell.selectionStyle = .none
        return cell
    }
}
#endif
