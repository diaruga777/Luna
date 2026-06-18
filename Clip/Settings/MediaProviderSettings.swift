//
//  MediaProviderSettings.swift
//  Clip
//

import UIKit

/// The user's preferred app for opening music / podcast items (provider-portable
/// links resolve to this). Defaults to `.apple` until the user picks otherwise. App
/// Group so the intent runner reads the same value.
enum MediaProviderSettings {
    private static let musicKey = "preferredMusicProvider"
    private static let podcastKey = "preferredPodcastProvider"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    static var preferredMusicProvider: MusicProvider {
        get { defaults.string(forKey: musicKey).flatMap(MusicProvider.init(rawValue:)) ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: musicKey) }
    }

    static var preferredPodcastProvider: MusicProvider {
        get { defaults.string(forKey: podcastKey).flatMap(MusicProvider.init(rawValue:)) ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: podcastKey) }
    }

    /// Preferred provider for a platform kind (.music / .podcast).
    static func preferredProvider(for platform: ContentPlatform) -> MusicProvider {
        platform == .podcast ? preferredPodcastProvider : preferredMusicProvider
    }
}

/// Settings screen: pick the preferred Music and Podcast apps.
final class MediaProviderSettingsScreen: UITableViewController {

    private enum Row: Int, CaseIterable { case music, podcast }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Music & Podcasts"
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Choose which app opens saved songs and podcasts. Links from either service open in your preferred app."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let row = Row(rawValue: indexPath.row)!
        content.text = row == .music ? "Music" : "Podcasts"
        cell.selectionStyle = .none

        let control = UISegmentedControl(items: MusicProvider.allCases.map(\.displayName))
        let current = row == .music
            ? MediaProviderSettings.preferredMusicProvider
            : MediaProviderSettings.preferredPodcastProvider
        control.selectedSegmentIndex = MusicProvider.allCases.firstIndex(of: current) ?? 0
        control.tag = indexPath.row
        control.addTarget(self, action: #selector(providerChanged(_:)), for: .valueChanged)
        cell.accessoryView = control
        cell.contentConfiguration = content
        return cell
    }

    @objc private func providerChanged(_ control: UISegmentedControl) {
        let provider = MusicProvider.allCases[
            max(0, min(control.selectedSegmentIndex, MusicProvider.allCases.count - 1))]
        switch Row(rawValue: control.tag) {
        case .music: MediaProviderSettings.preferredMusicProvider = provider
        case .podcast: MediaProviderSettings.preferredPodcastProvider = provider
        case nil: break
        }
    }
}
