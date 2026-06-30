//
//  FriendPickerSheet.swift
//  Lune
//

import LuneSocial
import LuneDesignSystem
import UIKit

/// A modern bottom sheet for picking a friend to send to: a wide card whose height
/// adapts to the friend list (a scrollable table when it gets tall), replacing the
/// old `UIAlertController(.actionSheet)`. Tapping a friend sends and dismisses.
public final class FriendPickerSheet: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let friends: [Friend]
    private let onPick: (Friend) -> Void
    private let tableView = UITableView(frame: .zero, style: .plain)

    private static let rowHeight: CGFloat = 56
    private static let headerHeight: CGFloat = 60

    public init(friends: [Friend], onPick: @escaping (Friend) -> Void) {
        self.friends = friends
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        if let sheet = sheetPresentationController {
            let count = friends.count
            sheet.detents = [.custom(identifier: .init("friendPicker")) { context in
                let content = Self.headerHeight + CGFloat(count) * Self.rowHeight + 24
                return min(content, context.maximumDetentValue * 0.85)
            }]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "Send to a Friend"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Self.rowHeight
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "friend")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        friends.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "friend", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = friends[indexPath.row].card.username
        content.image = UIImage(systemName: "person.crop.circle.fill")
        content.imageProperties.tintColor = GlassStyle.readingAccent
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let friend = friends[indexPath.row]
        dismiss(animated: true) { [onPick] in onPick(friend) }
    }
}
