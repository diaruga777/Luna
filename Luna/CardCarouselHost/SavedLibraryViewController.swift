import LunaDesignSystem
import LunaModels
import LunaStorage
import UIKit

enum SavedLibraryFilter: String, CaseIterable {
    case inProgress = "In progress", text = "Text", video = "Video", shopping = "Shopping"

    var title: String {
        switch self {
        case .inProgress: return L10n.string("Library_inProgress")
        case .text: return L10n.string("Library_text")
        case .video: return L10n.string("Library_video")
        case .shopping: return L10n.string("Library_shopping")
        }
    }

    static func includes(_ item: SavedItem, filters: Set<Self>, isVideo: Bool) -> Bool {
        if filters.contains(.inProgress) {
            let hasPosition = (item.readingProgress ?? 0) > 0 || (item.lastWordIndex ?? 0) > 0
                || (item.lastScrollOffset ?? 0) > 0 || (item.lastOriginalScrollOffset ?? 0) > 0 || (item.lastSpokenWordIndex ?? 0) > 0
            guard hasPosition, item.readState != .read, (item.readingProgress ?? 0) < 1 else { return false }
        }
        let kinds = filters.subtracting([.inProgress])
        guard !kinds.isEmpty else { return true }
        return kinds.contains(.text) && item.exportKind == .article
            || kinds.contains(.video) && isVideo
            || kinds.contains(.shopping) && item.isPriceTracker
    }
}

struct SavedLibraryEntry {
    let item: SavedItem
    let isVideo: Bool
    let loadBanner: (@escaping (UIImage?) -> Void) -> Void
    let loadBadge: (@escaping (CarouselSourceBadge?) -> Void) -> Void
}

/// Lightweight reusable rows: no reader controllers, prose layout, or players.
final class SavedLibraryViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout, UISearchBarDelegate {
    var entries: [SavedLibraryEntry] = [] { didSet { if isViewLoaded { applyResults() } } }
    var didSelect: ((UUID) -> Void)?
    private let searchBar = UISearchBar()
    private let pills = UIStackView()
    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var filters = Set<SavedLibraryFilter>()
    private var visible: [SavedLibraryEntry] = []
    private var matchedIDs: [UUID]?
    private var queryRevision = 0
    private var pendingSearch: DispatchWorkItem?
    private let searchQueue = DispatchQueue(label: "luna.library.query", qos: .userInitiated)
    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        let title = UILabel()
        title.text = L10n.string("Library_title")
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = L10n.string("Library_close")
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        let heading = UIStackView(arrangedSubviews: [title, UIView(), close])
        heading.alignment = .center
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true
        close.heightAnchor.constraint(equalToConstant: 44).isActive = true
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = L10n.string("Library_search")
        searchBar.delegate = self
        searchBar.accessibilityIdentifier = "savedLibrary.search"
        let pillScroll = UIScrollView()
        pillScroll.showsHorizontalScrollIndicator = false
        pills.spacing = 8
        pills.translatesAutoresizingMaskIntoConstraints = false
        pillScroll.addSubview(pills)
        NSLayoutConstraint.activate([
            pills.leadingAnchor.constraint(equalTo: pillScroll.contentLayoutGuide.leadingAnchor),
            pills.trailingAnchor.constraint(equalTo: pillScroll.contentLayoutGuide.trailingAnchor),
            pills.topAnchor.constraint(equalTo: pillScroll.contentLayoutGuide.topAnchor),
            pills.bottomAnchor.constraint(equalTo: pillScroll.contentLayoutGuide.bottomAnchor),
            pills.heightAnchor.constraint(equalTo: pillScroll.frameLayoutGuide.heightAnchor),
        ])
        for filter in SavedLibraryFilter.allCases {
            let button = UIButton(type: .system)
            button.accessibilityIdentifier = "savedLibrary.filter.\(filter)"
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if self.filters.contains(filter) { self.filters.remove(filter) }
                else { self.filters.insert(filter) }
                self.updatePills()
                self.applyResults()
            }, for: .touchUpInside)
            pills.addArrangedSubview(button)
        }
        updatePills()
        let chrome = UIStackView(arrangedSubviews: [heading, searchBar, pillScroll])
        chrome.axis = .vertical
        chrome.spacing = 8
        chrome.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chrome)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.keyboardDismissMode = .onDrag
        collection.alwaysBounceVertical = true
        collection.accessibilityIdentifier = "savedLibrary.cards"
        collection.register(SavedLibraryCell.self, forCellWithReuseIdentifier: "card")
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        collection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collection)
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.numberOfLines = 0
        collection.backgroundView = emptyLabel
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            chrome.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            chrome.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            pillScroll.heightAnchor.constraint(equalToConstant: 44),
            collection.topAnchor.constraint(equalTo: chrome.bottomAnchor, constant: 16),
            collection.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            collection.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            collection.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(indexUpdated), name: SavedLibrarySearchIndex.didUpdate, object: nil)
        applyResults()
    }

    deinit { pendingSearch?.cancel(); NotificationCenter.default.removeObserver(self) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let columns = traitCollection.userInterfaceIdiom == .pad && collection.bounds.width >= 700 ? 2 : 1
        let width = (collection.bounds.width - CGFloat(columns - 1) * 12) / CGFloat(columns)
        let height = max(112, UIFont.preferredFont(forTextStyle: .headline).lineHeight * 3 + 32)
        let size = CGSize(width: max(1, width), height: height)
        if layout.itemSize != size { layout.itemSize = size; layout.invalidateLayout() }
    }

    private func updatePills() {
        for (filter, view) in zip(SavedLibraryFilter.allCases, pills.arrangedSubviews) {
            guard let button = view as? UIButton else { continue }
            let selected = filters.contains(filter)
            var config = selected ? UIButton.Configuration.filled() : .tinted()
            config.title = filter.title
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
                return attributes
            }
            config.baseBackgroundColor = selected ? .systemIndigo : .secondarySystemFill
            config.baseForegroundColor = selected ? .white : .label
            button.configuration = config
            button.isSelected = selected
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    private func applyResults() {
        let eligible = entries.filter { SavedLibraryFilter.includes($0.item, filters: filters, isVideo: $0.isVideo) }
        if let matchedIDs {
            let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.item.id, $0) })
            visible = matchedIDs.compactMap { byID[$0] }
        } else { visible = eligible }
        emptyLabel.text = visible.isEmpty ? (entries.isEmpty ? L10n.string("Library_empty") : L10n.string("Library_noMatches")) : nil
        collection.reloadData()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { search(searchText) }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    @objc private func indexUpdated() { search(searchBar.text ?? "") }

    private func search(_ text: String) {
        pendingSearch?.cancel()
        queryRevision += 1
        let revision = queryRevision
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            matchedIDs = nil
            applyResults()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            do {
                let ids = try SavedLibrarySearchIndex.shared.matches(text)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.queryRevision == revision else { return }
                    self.matchedIDs = ids
                    self.applyResults()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.queryRevision == revision else { return }
                    self.visible = []
                    self.emptyLabel.text = L10n.string("Library_searchUnavailable")
                    self.collection.reloadData()
                }
            }
        }
        pendingSearch = work
        searchQueue.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { visible.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! SavedLibraryCell
        cell.configure(visible[indexPath.item])
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let id = visible[indexPath.item].item.id
        view.endEditing(true)
        dismiss(animated: true) { [weak self] in self?.didSelect?(id) }
    }
}

private final class SavedLibraryCell: UICollectionViewCell {
    private let banner = UIImageView()
    private let treatment = UIView()
    private let title = UILabel()
    private let badge = CarouselSourceBadgeView()
    private var representedID: UUID?
    private var generation = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 20
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        banner.contentMode = .scaleAspectFill
        banner.clipsToBounds = true
        treatment.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 3
        for child in [banner, treatment, badge, title] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(child)
        }
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            banner.topAnchor.constraint(equalTo: contentView.topAnchor),
            banner.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            treatment.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            treatment.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            treatment.topAnchor.constraint(equalTo: banner.topAnchor),
            treatment.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            badge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30), badge.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            title.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func prepareForReuse() { super.prepareForReuse(); representedID = nil; setBanner(nil); badge.setBadge(.symbol("globe")) }
    func configure(_ entry: SavedLibraryEntry) {
        representedID = entry.item.id
        generation += 1
        let generation = self.generation
        // URLs are deliberately absent, including the untitled fallback.
        title.text = entry.item.title?.isEmpty == false ? entry.item.title : L10n.string("Common_untitled")
        accessibilityLabel = title.text
        setBanner(nil)
        badge.setBadge(.symbol("globe"))
        entry.loadBanner { [weak self] image in
            guard self?.representedID == entry.item.id, self?.generation == generation else { return }
            self?.setBanner(image)
        }
        entry.loadBadge { [weak self] value in
            guard self?.representedID == entry.item.id, self?.generation == generation else { return }
            self?.badge.setBadge(value ?? .symbol("globe"))
        }
    }
    private func setBanner(_ image: UIImage?) {
        banner.image = image
        treatment.isHidden = image == nil
        title.textColor = image == nil ? .label : .white
    }
}
