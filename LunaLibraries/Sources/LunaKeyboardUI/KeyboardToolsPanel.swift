import ImageIO
import LunaKeyboardCore
import LunaStorage
import UIKit
import UniformTypeIdentifiers

/// A content shelf above a shared glass search bar. The document is never the search buffer.
final class KeyboardToolsPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UITextFieldDelegate {
  var onText: ((String) -> Void)?
  var onClose: (() -> Void)?
  var onReturnTitle: ((String) -> Void)?
  let searchField = UITextField()
  let collection: UICollectionView
  private let close = UIButton(type: .system)
  private let activity = UIActivityIndicatorView(style: .medium)
  private let chrome = KeyboardAppearance.glassContainer()
  private let searchGlass = KeyboardAppearance.glass()
  private let closeGlass = KeyboardAppearance.glass(interactive: true)
  private let saveGlass = KeyboardAppearance.glass(interactive: true)
  private let emptyState = UIStackView()
  private let emptyTitle = UILabel()
  private let emptyDetail = UILabel()
  private let catalog: KeyboardCatalog
  private let store: KeyboardStore?
  private let fullAccess: Bool
  private let compact: Bool
  private let fetch: (String) async throws -> [KeyboardMediaSearch.Result]
  private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
  private var tasks: [Task<Void, Never>] = []
  private var copyTask: Task<Void, Never>?
  private var timer: Timer?
  private var generation = 0
  private var pending = 0
  private var localPending = false
  private var localTask: Task<Void, Never>?
  private var preparedQuery: String?
  private actor LocalSearch {
    static let shared = LocalSearch()
    func items(query: String, catalog: KeyboardCatalog, store: KeyboardStore?) -> [Item] {
      guard !Task.isCancelled else { return [] }
      return KeyboardToolsPanel.savedItems(query: query, catalog: catalog, store: store)
    }
  }
  private var localItems: [Item] = []
  private var remoteItems: [Item] = []
  private var errors: [String] = []
  private(set) var items: [Item] = []
  private let clipboard: KeyboardSearchClipboard
  private var copied: Item? { get { clipboard.item } set { clipboard.item = newValue } }
  private var copiedFile: URL? { get { clipboard.file } set { clipboard.file = newValue } }
  private let copiedPreview = KeyboardMediaPreview()
  private let copiedButton = UIButton(type: .custom)
  private var tagging = false
  private var previousQuery = ""
  private var loadingID: String?
  private var copiedID: String?
  private let focusedPreview = KeyboardMediaPreview()
  private let save = UIButton(type: .system)
  var searchStatus: String? { emptyState.isHidden ? nil : emptyTitle.text }
  var query: String { searchField.text ?? "" }
  var requiredHeight: CGFloat { (compact ? 85 : 120) + 66 }

  struct Item {
    let id: String
    let title: String
    var text: String?
    var shortcut: KeyboardShortcut?
    var url: URL?
    var thumbnail: URL?
    var gif = false
    var attribution = "Saved shortcut"
    var isCopied = false
    var isError = false
  }

  init(catalog: KeyboardCatalog, store: KeyboardStore?, fullAccess: Bool, compact: Bool = false, clipboard: KeyboardSearchClipboard = KeyboardSearchClipboard(),
       fetch: @escaping (String) async throws -> [KeyboardMediaSearch.Result] = { try await KeyboardMediaSearch.search($0) }) {
    self.catalog = catalog; self.store = store; self.fullAccess = fullAccess; self.compact = compact; self.fetch = fetch; self.clipboard = clipboard
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 10
    layout.sectionInset = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
    collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(frame: .zero)
    accessibilityIdentifier = "keyboard.searchPanel"
    backgroundColor = .clear
    collection.backgroundColor = .clear
    collection.showsHorizontalScrollIndicator = false
    collection.delegate = self
    collection.isPrefetchingEnabled = false
    dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, index, id in
      guard let self else { return nil }
      guard let item = self.items.first(where: { $0.id == id }) else { return nil }
      let cell = collection.dequeueReusableCell(withReuseIdentifier: "glyph", for: index) as! KeyboardMediaCell
      self.configure(cell, item: item, index: index)
      return cell
    }
    collection.register(KeyboardMediaCell.self, forCellWithReuseIdentifier: "glyph")
    collection.accessibilityIdentifier = "keyboard.searchResults"
    searchField.font = .systemFont(ofSize: 17)
    searchField.placeholder = "Emoji, shortcuts & GIFs"
    searchField.accessibilityLabel = "Search emoji, shortcuts and GIFs"
    searchField.accessibilityIdentifier = "keyboard.searchField"
    searchField.autocapitalizationType = .none
    searchField.autocorrectionType = .no
    searchField.spellCheckingType = .no
    searchField.returnKeyType = .search
    searchField.clearButtonMode = .whileEditing
    searchField.tintColor = .systemBlue
    searchField.inputView = UIView(frame: .zero)
    let inset = UIView(frame: CGRect(x: 0, y: 0, width: 36, height: 42))
    let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)))
    magnifier.tintColor = .secondaryLabel
    magnifier.frame = CGRect(x: 12, y: 12, width: 18, height: 18)
    inset.addSubview(magnifier)
    searchField.leftView = inset; searchField.leftViewMode = .always
    searchField.delegate = self
    searchField.addAction(UIAction { [weak self] _ in self?.schedule() }, for: .editingChanged)
    close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    close.accessibilityLabel = "Close search"
    close.accessibilityIdentifier = "keyboard.closeSearch"
    close.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      if self.tagging { self.finishTagging() } else { self.onClose?() }
    }, for: .touchUpInside)
    save.setTitle("Save", for: .normal)
    save.accessibilityIdentifier = "keyboard.saveMedia"
    save.addAction(UIAction { [weak self] _ in self?.saveCopied() }, for: .touchUpInside)
    save.isHidden = true; focusedPreview.isHidden = true
    [collection, emptyState, chrome, focusedPreview, copiedPreview, copiedButton].forEach(addSubview)
    [closeGlass, searchGlass, saveGlass].forEach(chrome.contentView.addSubview)
    closeGlass.contentView.addSubview(close)
    searchGlass.contentView.addSubview(searchField)
    searchGlass.contentView.addSubview(activity)
    saveGlass.contentView.addSubview(save)
    saveGlass.isHidden = true
    save.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    emptyState.axis = .vertical
    emptyState.alignment = .center
    emptyState.spacing = 6
    emptyState.isUserInteractionEnabled = false
    emptyTitle.font = .systemFont(ofSize: 17, weight: .semibold)
    emptyTitle.textColor = .label
    emptyDetail.font = .systemFont(ofSize: 13)
    emptyDetail.textColor = .secondaryLabel
    emptyDetail.numberOfLines = 2
    emptyDetail.textAlignment = .center
    emptyState.addArrangedSubview(emptyTitle)
    emptyState.addArrangedSubview(emptyDetail)
    emptyState.isHidden = true
    copiedButton.accessibilityLabel = "Copied item. Add keywords"
    copiedButton.accessibilityIdentifier = "keyboard.copiedPreview"
    copiedButton.addAction(UIAction { [weak self] _ in self?.beginTagging() }, for: .touchUpInside)
    copiedPreview.layer.borderWidth = 2
    copiedPreview.layer.borderColor = UIColor.systemBlue.cgColor
    copiedPreview.load(copiedFile, text: copied?.text)
    copiedPreview.isHidden = copied == nil; copiedButton.isHidden = copied == nil
    searchNow()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  deinit {
    tasks.forEach { $0.cancel() }; localTask?.cancel(); copyTask?.cancel(); timer?.invalidate()
  }
  func setDark(_ dark: Bool) {
    overrideUserInterfaceStyle = dark ? .dark : .light
    searchField.backgroundColor = .clear
    searchField.textColor = .label
    close.tintColor = .label
    save.tintColor = .systemBlue
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let cellHeight: CGFloat = compact ? 85 : 120
    collection.frame = CGRect(x: 0, y: 8, width: bounds.width, height: cellHeight)
    emptyState.frame = CGRect(x: 24, y: 8 + (cellHeight - 56) / 2, width: max(0, bounds.width - 48), height: 56)
    chrome.frame = CGRect(x: 8, y: cellHeight + 16, width: max(0, bounds.width - 16), height: 42)
    closeGlass.frame = CGRect(x: 0, y: 0, width: 42, height: 42)
    close.frame = closeGlass.bounds
    searchGlass.frame = CGRect(x: 50, y: 0, width: max(0, chrome.bounds.width - 50 - (tagging ? 62 : 0)), height: 42)
    searchField.frame = searchGlass.bounds.insetBy(dx: 0, dy: 0)
    // Reserve the trailing accessory for progress; never cover the Clear button.
    activity.frame = CGRect(x: 0, y: 0, width: 32, height: 42)
    focusedPreview.frame = CGRect(x: (bounds.width - cellHeight) / 2, y: 8, width: cellHeight, height: cellHeight)
    saveGlass.frame = CGRect(x: chrome.bounds.width - 54, y: 0, width: 54, height: 42)
    save.frame = saveGlass.bounds
    saveGlass.isHidden = !tagging
    layoutCopiedPreview()
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { searchField.becomeFirstResponder() }
  }
  func appendSearch(_ value: String) { searchField.insertText(value); schedule() }
  func deleteSearch() { searchField.deleteBackward(); schedule() }
  func moveCursor(_ offset: Int) {
    guard let range = searchField.selectedTextRange,
      let position = searchField.position(from: range.start, offset: offset) else { return }
    searchField.selectedTextRange = searchField.textRange(from: position, to: position)
  }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool { submit(); return false }
  func submit() { if tagging { saveCopied() } else { searchNow() } }
  func cancelWork() {
    generation += 1
    timer?.invalidate(); timer = nil
    tasks.forEach { $0.cancel() }; tasks = []
    localTask?.cancel(); localTask = nil
    copyTask?.cancel(); copyTask = nil
    loadingID = nil
    preparedQuery = nil
    pending = 0; localPending = false
    activity.stopAnimating()
    collection.visibleCells.forEach { ($0 as? KeyboardMediaCell)?.preview.reset() }
    copiedPreview.reset(); focusedPreview.reset()
  }
  private func schedule() {
    guard prepareSearch() else { return }
    guard fullAccess, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !tagging else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in self?.fetchRemote() }
  }
  func searchNow() { if prepareSearch(force: true) { fetchRemote() } }
  @discardableResult private func prepareSearch(force: Bool = false) -> Bool {
    guard !tagging else { return false }
    let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128)).styleErased
    guard force || preparedQuery != query else { return false }
    preparedQuery = query
    generation += 1
    timer?.invalidate(); timer = nil
    tasks.forEach { $0.cancel() }; tasks = []
    localTask?.cancel()
    copyTask?.cancel(); copyTask = nil; loadingID = nil
    localItems = []; remoteItems = []; errors = []
    localPending = true
    // Loading starts with the edit, including the remote debounce interval.
    pending = fullAccess && !query.isEmpty ? 1 : 0
    if !fullAccess, !query.isEmpty { errors = ["Enable Full Access for GIF search."] }
    rebuildItems(resetScroll: true)
    let gen = generation
    let catalog = self.catalog, store = self.store
    localTask = Task { [weak self] in
      // A serial worker bounds outstanding SQLite reads. Never wait for the
      // shared store's lock on the typing thread, even for an empty query.
      let found = await LocalSearch.shared.items(query: query, catalog: catalog, store: store)
      guard !Task.isCancelled, let self, self.generation == gen else { return }
      self.localPending = false
      self.localItems = found
      self.rebuildItems()
    }
    return true
  }
  private func fetchRemote() {
    guard !tagging else { return }
    let query = preparedQuery ?? ""
    guard fullAccess, !query.isEmpty else { return }
    let gen = generation
    pending = 1; activity.startAnimating()
    let fetch = self.fetch
    let store = self.store
    tasks = [Task { [weak self] in
      // Provider JSON and cache IO stay off the typing/UI thread.
      let worker = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        let key = "gif-v4:" + query.lowercased()
        let cached = try? store?.cachedMediaSearch(key)
        let decoded = cached.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([KeyboardMediaSearch.Result].self, from: $0) }
        let fetched: [KeyboardMediaSearch.Result]
        try Task.checkCancellation()
        if let decoded { fetched = decoded } else { fetched = try await fetch(query) }
        try Task.checkCancellation()
        var seen = Set<URL>()
        let found = Array(fetched.filter { $0.url.scheme == "https" && seen.insert($0.url).inserted }.prefix(24))
        if decoded == nil, let data = try? JSONEncoder().encode(found), let json = String(data: data, encoding: .utf8) {
          try? store?.cacheMediaSearch(key, payload: json)
        }
        return found
      }
      do {
        let found = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, let self, self.generation == gen else { return }
        self.remoteItems = found.map { Item(id: "remote:" + $0.url.absoluteString, title: $0.title, url: $0.url, thumbnail: $0.thumbnail, gif: true, attribution: "GIPHY · \($0.title)") }
        self.finishedSearch()
      } catch {
        guard !Task.isCancelled, let self, self.generation == gen else { return }
        self.errors = ["GIF search unavailable. Tap to retry."]
        self.finishedSearch()
      }
    }]
  }
  private func finishedSearch() {
    pending = 0
    rebuildItems()
  }
  nonisolated private static func savedItems(query: String, catalog: KeyboardCatalog, store: KeyboardStore?) -> [Item] {
    let saved = ((try? store?.searchShortcuts(query, limit: 40)) ?? []).map { shortcut in
      Item(id: "saved:" + shortcut.id, title: shortcut.text, text: shortcut.kind == "text" ? shortcut.text : nil,
           shortcut: shortcut, url: store?.fileURL(for: shortcut), gif: shortcut.kind == "gif")
    }
    guard !Task.isCancelled else { return [] }
    let builtins: [Item] = [
      Item(id: "wat", title: "Wat", url: KeyboardResources.url("wat", extension: "png")),
      Item(id: "dramatic", title: "Dramatic chipmunk", url: KeyboardResources.url("dramatic_chipmunk", extension: "gif"), gif: true),
    ].filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    let defaults: [Item] = query.isEmpty ? [Item(id: "shrug", title: "Shrug", text: "¯\\_(ツ)_/¯")] : []
    let glyphs = catalog.browseGlyphs(query: query, limit: 40).map { Item(id: "glyph:" + $0.text, title: $0.name, text: $0.text) }
    guard !Task.isCancelled else { return [] }
    let links = ((try? store?.recentLinks(limit: 12, query: query)) ?? []).map { Item(id: "link:" + $0.id, title: $0.title, text: $0.url) }
    return saved + builtins + defaults + glyphs + links
  }
  private func rebuildItems(resetScroll: Bool = false) {
    // All local matches rank ahead of remote GIFs, in the same horizontal row.
    var seen = Set<String>()
    items = (localItems + remoteItems).filter { seen.insert($0.id).inserted }
    items += errors.map { Item(id: $0, title: $0, text: nil, isError: true) }
    let loading = localPending || pending > 0
    if loading { activity.startAnimating() } else { activity.stopAnimating() }
    searchField.rightView = loading ? activity : nil
    searchField.rightViewMode = loading ? .always : .never
    emptyState.isHidden = !items.isEmpty || tagging
    emptyTitle.text = loading ? "Searching…" : "No results"
    emptyDetail.text = loading ? "Finding emoji, shortcuts and GIFs" : "Try a different word or phrase."
    collection.contentInset.left = copied == nil ? 0 : (compact ? 85 : 120)
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(items.map(\.id))
    dataSource.apply(snapshot, animatingDifferences: false)
    updateFeedback()
    if resetScroll { collection.setContentOffset(CGPoint(x: -collection.contentInset.left, y: 0), animated: false) }
    layoutCopiedPreview()
  }
  func scrollViewDidScroll(_ scrollView: UIScrollView) { layoutCopiedPreview() }
  private func layoutCopiedPreview() {
    let height: CGFloat = compact ? 85 : 120
    let collapse = min(1, max(0, (42 + collection.contentOffset.x) / 42))
    let size = height * (1 - collapse * 0.5)
    let frame = CGRect(x: 8, y: 8 + height - size, width: size, height: size)
    copiedPreview.frame = frame
    copiedPreview.layer.cornerRadius = size * max(0.2, collapse * 0.5)
    copiedButton.frame = frame
    copiedPreview.isHidden = copied == nil || tagging
    copiedButton.isHidden = copiedPreview.isHidden
  }
  private func updateFeedback() {
    for cell in collection.visibleCells {
      guard let index = collection.indexPath(for: cell), index.item < items.count,
        let cell = cell as? KeyboardMediaCell else { continue }
      let item = items[index.item]
      cell.showFeedback(item.id == loadingID ? "Copying…" : item.id == copiedID ? "Copied ✓" : item.isCopied ? "Add keywords" : nil)
    }
  }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
    let height: CGFloat = compact ? 85 : 120
    let item = items[indexPath.item]
    let width = item.text.map { min(compact ? 120 : 160, max(height, ($0 as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 20)]).width + 16)) } ?? height
    return CGSize(width: width, height: height)
  }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "glyph", for: indexPath) as! KeyboardMediaCell
    let item = items[indexPath.item]
    configure(cell, item: item, index: indexPath)
    return cell
  }
  private func configure(_ cell: KeyboardMediaCell, item: Item, index: IndexPath) {
    cell.preview.load(item.thumbnail ?? item.url, text: item.url == nil ? (item.text ?? item.title) : nil, animating: item.gif)
    cell.accessibilityLabel = item.isCopied ? "Copied \(item.title). Add keywords" : item.title
    cell.accessibilityIdentifier = "keyboard.result.\(index.item)"
    cell.accessibilityHint = item.isError ? (fullAccess ? "Retry search" : "Allow Full Access in Settings to search GIFs") : item.text != nil ? "Insert text" : "Copy, then paste into your message"
    cell.setCaption(item.isError ? "" : item.id.hasPrefix("remote:") ? "GIPHY" : item.attribution == "Saved shortcut" ? (item.shortcut == nil ? "" : "Shortcut") : item.attribution)
    cell.preview.isStatus = item.isError
    cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: item.attribution) { _ in true }]
    cell.showFeedback(item.id == loadingID ? "Copying…" : item.id == copiedID ? "Copied ✓" : item.isCopied ? "Add keywords" : nil)
  }
  func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
    guard let cell = cell as? KeyboardMediaCell, indexPath.item < items.count else { return }
    configure(cell, item: items[indexPath.item], index: indexPath)
  }
  func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { if !collectionView.visibleCells.contains(cell) { (cell as? KeyboardMediaCell)?.preview.reset() } }
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { select(items[indexPath.item]) }
  func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
    let item = items[indexPath.item]
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      UIMenu(title: item.attribution, children: [UIAction(title: item.text == nil ? "Copy" : "Insert", image: UIImage(systemName: "doc.on.doc")) { _ in self?.select(item) }])
    }
  }
  private func select(_ item: Item) {
    if item.isCopied { beginTagging(); return }
    if item.isError { searchNow(); return }
    if let text = item.text { onText?(text); return }
    guard fullAccess, let url = item.url else { return }
    copyTask?.cancel(); loadingID = item.id; copiedID = nil; updateFeedback()
    copyTask = Task { [weak self] in
      do {
        let local = url.isFileURL ? url : try await KeyboardMediaSearch.download(url, maxBytes: 8 * 1024 * 1024)
        defer { if !url.isFileURL { try? FileManager.default.removeItem(at: local) } }
        let worker = Task.detached(priority: .utility) { () throws -> (Data, String, URL) in
          try Task.checkCancellation()
          let size = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
          guard size <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
          let data = try Data(contentsOf: local, options: .mappedIfSafe)
          guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source) else { throw URLError(.cannotDecodeContentData) }
          let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(item.gif ? "gif" : "png")
          try Task.checkCancellation()
          try data.write(to: file)
          return (data, type as String, file)
        }
        let (data, type, file) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, let self else { try? FileManager.default.removeItem(at: file); return }
        UIPasteboard.general.setData(data, forPasteboardType: type)
        if let old = self.copiedFile { try? FileManager.default.removeItem(at: old) }
        self.copiedFile = file
        var copied = item; copied.url = file; copied.thumbnail = file; copied.isCopied = true
        self.copied = copied
        self.copiedPreview.load(file)
        self.loadingID = nil; self.copiedID = item.id
        self.rebuildItems()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
          guard self?.copiedID == item.id else { return }
          self?.copiedID = nil; self?.updateFeedback()
        }
        UIAccessibility.post(notification: .announcement, argument: "Copied. Paste into your message, or tap the copied preview to add keywords.")
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.loadingID = nil
        self.errors = ["Couldn’t copy this item. Try another result."]
        self.rebuildItems()
      }
    }
  }
  func beginTagging() {
    guard let copied else { return }
    localTask?.cancel(); localTask = nil
    copyTask?.cancel(); copyTask = nil; loadingID = nil
    tagging = true; previousQuery = query
    copiedPreview.reset()
    collection.visibleCells.forEach { ($0 as? KeyboardMediaCell)?.preview.reset() }
    layoutCopiedPreview()
    timer?.invalidate(); generation += 1; tasks.forEach { $0.cancel() }; activity.stopAnimating()
    collection.isHidden = true; emptyState.isHidden = true; focusedPreview.isHidden = false; save.isHidden = false
    focusedPreview.load(copied.url, text: copied.text)
    searchField.text = copied.shortcut?.keywords.joined(separator: ", ") ?? query
    searchField.placeholder = "Add keywords, separated by commas"
    close.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    close.accessibilityLabel = "Back to search"
    onReturnTitle?("save"); setNeedsLayout()
    searchField.becomeFirstResponder()
  }
  private func finishTagging() {
    tagging = false; searchField.text = previousQuery
    searchField.placeholder = "Emoji, shortcuts & GIFs"
    collection.isHidden = false; focusedPreview.isHidden = true; save.isHidden = true
    focusedPreview.reset()
    copiedPreview.load(copiedFile, text: copied?.text)
    close.setImage(UIImage(systemName: "xmark"), for: .normal)
    close.accessibilityLabel = "Close search"
    onReturnTitle?("search"); setNeedsLayout(); searchNow()
  }
  private func saveCopied() {
    guard let copied, let store, let copiedFile else { return }
    let keywords = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !keywords.isEmpty else { return }
    do {
      var shortcut = copied.shortcut ?? KeyboardShortcut(keywords: keywords, text: copied.title, kind: copied.gif ? "gif" : "image")
      shortcut.keywords = keywords
      try store.save(shortcut, importing: shortcut.relativePath == nil ? copiedFile : nil)
      self.copied?.shortcut = try store.shortcuts(matching: keywords[0]).first { $0.id == shortcut.id }
      UIAccessibility.post(notification: .announcement, argument: "Shortcut saved")
      finishTagging()
    } catch { searchField.placeholder = "Couldn’t save. Try again." }
  }
}

/// Retains only the explicitly copied item across closing/reopening the storefront.
/// Its temporary file is released with the keyboard, never imported implicitly.
final class KeyboardSearchClipboard {
  var item: KeyboardToolsPanel.Item?
  var file: URL?
  deinit { if let file { try? FileManager.default.removeItem(at: file) } }
}
