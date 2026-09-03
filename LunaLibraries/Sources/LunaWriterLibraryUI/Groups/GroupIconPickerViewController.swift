import UIKit
import LunaDesignSystem
import LunaModels

/// A curated grid of SF Symbols for a group's icon. Picking one calls back
/// and dismisses.
public final class GroupIconPickerViewController: UICollectionViewController {

    /// The symbols on offer, in the order shown.
    public static let curatedSymbols = [
        "folder", "folder.fill", "book", "book.closed", "doc.text", "doc.richtext",
        "pencil", "pencil.and.outline", "lightbulb", "flame", "star", "heart",
        "tag", "bookmark", "archivebox", "tray", "list.bullet", "checklist",
        "quote.opening", "text.quote", "newspaper", "briefcase", "graduationcap",
        "globe", "map", "calendar", "person", "person.2", "leaf", "sparkles",
    ]

    private let currentIcon: String
    private let onPick: (String) -> Void

    public init(currentIcon: String, onPick: @escaping (String) -> Void) {
        self.currentIcon = currentIcon
        self.onPick = onPick
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .absolute(56)),
                subitems: Array(repeating: item, count: 5))
            group.interItemSpacing = .fixed(8)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 8
            section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
            return section
        }
        super.init(collectionViewLayout: layout)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_groups_changeIconTitle")
        collectionView.backgroundColor = LunaColors.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_cancel"), style: .plain, target: self,
            action: #selector(cancelTapped))
        collectionView.register(
            IconCell.self, forCellWithReuseIdentifier: IconCell.reuseIdentifier)
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    public override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        Self.curatedSymbols.count
    }

    public override func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: IconCell.reuseIdentifier, for: indexPath) as! IconCell
        let symbol = Self.curatedSymbols[indexPath.item]
        cell.configure(symbol: symbol, isSelected: symbol == currentIcon)
        return cell
    }

    public override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPick(Self.curatedSymbols[indexPath.item])
        dismiss(animated: true)
    }

    private final class IconCell: UICollectionViewCell {
        static let reuseIdentifier = "GroupIconPickerCell"
        private let imageView = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            imageView.contentMode = .center
            imageView.tintColor = LunaColors.primaryText
            imageView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func configure(symbol: String, isSelected: Bool) {
            imageView.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            backgroundColor = isSelected
                ? LunaColors.tertiaryFill : LunaColors.secondaryBackground
        }
    }
}
