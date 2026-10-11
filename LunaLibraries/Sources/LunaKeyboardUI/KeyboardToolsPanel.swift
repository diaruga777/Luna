import ImageIO
import LunaKeyboardCore
import LunaStorage
import UIKit
import UniformTypeIdentifiers

/// Clack's storefront: one query, a horizontal row of glyphs, and the search
/// field directly above the typing keys. The document is never the search buffer.
final class KeyboardToolsPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UITextFieldDelegate {
  var onText: ((String) -> Void)?
  var onClose: (() -> Void)?
  var onReturnTitle: ((String) -> Void)?
  let searchField = UITextField()
  let collection: UICollectionView
  private let close = UIButton(type: .system)
  private let activity = UIActivityIndicatorView(style: .medium)
  private let catalog: KeyboardCatalog
  private let store: KeyboardStore?
  private let fullAccess: Bool
  private let compact: Bool
  private let fetch: (String, Bool) async throws -> [KeyboardMediaSearch.Result]
  private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
  private var tasks: [Task<Void, Never>] = []
  private var copyTask: Task<Void, Never>?
  private var timer: Timer?
  private var generation = 0
  private var pending = 0
  private var localItems: [Item] = []
  private var remoteItems: [[Item]] = [[], []]
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
       fetch: @escaping (String, Bool) async throws -> [KeyboardMediaSearch.Result] = { try await KeyboardMediaSearch.search($0, gifs: $1) }) {
    self.catalog = catalog; self.store = store; self.fullAccess = fullAccess; self.compact = compact; self.fetch = fetch; self.clipboard = clipboard
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 8
    layout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(frame: .zero)
    accessibilityIdentifier = "keyboard.searchPanel"
    backgroundColor = .clear
    collection.backgroundColor = .clear
    collection.showsHorizontalScrollIndicator = false
    collection.delegate = self
    dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, index, id in
      guard let self else { return nil }
      return self.collectionView(collection, cellForItemAt: index)
    }
    collection.register(KeyboardMediaCell.self, forCellWithReuseIdentifier: "glyph")
    collection.accessibilityIdentifier = "keyboard.searchResults"
    searchField.font = .systemFont(ofSize: 18)
    searchField.placeholder = "Search · Powered by GIPHY"
    searchField.accessibilityLabel = "Search emoji, shortcuts, GIFs and images"
    searchField.accessibilityIdentifier = "keyboard.searchField"
    searchField.autocapitalizationType = .none
    searchField.autocorrectionType = .no
    searchField.spellCheckingType = .no
    searchField.returnKeyType = .search
    searchField.clearButtonMode = .whileEditing
    searchField.layer.cornerRadius = 8
    searchField.inputView = UIView(frame: .zero)
    let inset = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 42))
    searchField.leftView = inset; searchField.leftViewMode = .always
    searchField.delegate = self
    searchField.addAction(UIAction { [weak self] _ in self?.schedule() }, for: .editingChanged)
    close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .ultraLight)), for: .normal)
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
    [collection, searchField, close, activity, focusedPreview, save, copiedPreview, copiedButton].forEach(addSubview)
    copiedButton.accessibilityLabel = "Copied item. Add keywords"
    copiedButton.accessibilityIdentifier = "keyboard.copiedPreview"
    copiedButton.addAction(UIAction { [weak self] _ in self?.beginTagging() }, for: .touchUpInside)
    copiedPreview.layer.borderWidth = 3
    copiedPreview.layer.borderColor = UIColor.gray.cgColor
    copiedPreview.load(copiedFile, text: copied?.text)
    copiedPreview.isHidden = copied == nil; copiedButton.isHidden = copied == nil
    searchNow()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  deinit {
    tasks.forEach { $0.cancel() }; copyTask?.cancel(); timer?.invalidate()
  }
  func setDark(_ dark: Bool) {
    searchField.backgroundColor = dark ? UIColor(red: 93/255, green: 95/255, blue: 90/255, alpha: 1) : UIColor(white: 0.9, alpha: 1)
    searchField.textColor = dark ? .white : .black
    close.tintColor = dark ? .white : .black
    save.tintColor = close.tintColor
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let cellHeight: CGFloat = compact ? 85 : 120
    collection.frame = CGRect(x: 0, y: 8, width: bounds.width, height: cellHeight)
    close.frame = CGRect(x: 0, y: cellHeight + 16, width: 42, height: 42)
    searchField.frame = CGRect(x: 42, y: cellHeight + 16, width: max(0, bounds.width - 50 - (tagging ? 54 : 0)), height: 42)
    activity.frame = CGRect(x: bounds.width - 38, y: 14, width: 24, height: 24)
    focusedPreview.frame = CGRect(x: (bounds.width - cellHeight) / 2, y: 8, width: cellHeight, height: cellHeight)
    save.frame = CGRect(x: bounds.width - 62, y: cellHeight + 16, width: 54, height: 42)
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
  private func schedule() {
    // Invalidate immediately: an older request must not win during the debounce.
    generation += 1
    tasks.forEach { $0.cancel() }; tasks = []
    timer?.invalidate()
    guard !tagging else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in self?.searchNow() }
  }
  func searchNow() {
    guard !tagging else { return }
    timer?.invalidate(); tasks.forEach { $0.cancel() }; tasks = []
    generation += 1
    let gen = generation
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines).styleErased
    localItems = savedItems(query: query)
    remoteItems = [[], []]; errors = []; pending = 0
    if !fullAccess, !query.isEmpty { errors = ["Enable Full Access for GIF and image search."] }
    rebuildItems(resetScroll: true)
    guard fullAccess, !query.isEmpty else { activity.stopAnimating(); return }
    pending = 2; activity.startAnimating()
    let fetch = self.fetch
    for index in 0..<2 {
      let gifs = index == 0
      tasks.append(Task { [weak self] in
        do {
          let key = (gifs ? "gif-v2:" : "image-v2:") + query.lowercased()
          let cached = try? self?.store?.cachedMediaSearch(key)
          let decoded = cached.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([KeyboardMediaSearch.Result].self, from: $0) }
          let fetched: [KeyboardMediaSearch.Result]
          if let decoded { fetched = decoded } else { fetched = try await fetch(query, gifs) }
          guard !Task.isCancelled, let self, self.generation == gen else { return }
          var seen = Set<URL>()
          let found = Array(fetched.filter { $0.url.scheme == "https" && seen.insert($0.url).inserted }.prefix(30))
          if decoded == nil, let data = try? JSONEncoder().encode(found), let json = String(data: data, encoding: .utf8) {
            try? self.store?.cacheMediaSearch(key, payload: json)
          }
          self.remoteItems[index] = found.map { Item(id: $0.url.absoluteString, title: $0.title, url: $0.url, thumbnail: $0.thumbnail, gif: gifs, attribution: gifs ? "GIPHY · \($0.title)" : "Image · \($0.title)") }
          self.finishedSearch()
        } catch {
          guard !Task.isCancelled, let self, self.generation == gen else { return }
          self.errors.append(gifs ? "GIF search unavailable. Tap to retry." : "Image search unavailable. Tap to retry.")
          self.finishedSearch()
        }
      })
    }
  }
  private func finishedSearch() {
    pending -= 1
    if pending == 0 { activity.stopAnimating() }
    rebuildItems()
  }
  private func savedItems(query: String) -> [Item] {
    let tokens = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    let saved = ((try? store?.shortcuts(limit: 500)) ?? []).filter { shortcut in
      tokens.isEmpty || tokens.contains { token in shortcut.keywords.contains { $0.localizedCaseInsensitiveContains(token) } || shortcut.text.localizedCaseInsensitiveContains(token) }
    }.map { shortcut in
      Item(id: shortcut.id, title: shortcut.text, text: shortcut.kind == "text" ? shortcut.text : nil,
           shortcut: shortcut, url: store?.fileURL(for: shortcut), gif: shortcut.kind == "gif")
    }
    let builtins: [Item] = [
      Item(id: "wat", title: "Wat", url: KeyboardResources.url("wat", extension: "png")),
      Item(id: "dramatic", title: "Dramatic chipmunk", url: KeyboardResources.url("dramatic_chipmunk", extension: "gif"), gif: true),
    ].filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    let defaults: [Item] = query.isEmpty ? [Item(id: "shrug", title: "Shrug", text: "¯\\_(ツ)_/¯")] : []
    let glyphs = catalog.browseGlyphs(query: query).map { Item(id: "glyph:" + $0.text, title: $0.name, text: $0.text) }
    let links = ((try? store?.recentLinks(limit: 20)) ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.map { Item(id: $0.id, title: $0.title, text: $0.url) }
    return saved + builtins + defaults + glyphs + links
  }
  private func rebuildItems(resetScroll: Bool = false) {
    // Clack interleaves local and remote matches instead of making users choose a tab.
    let sources = [localItems] + remoteItems
    items = []
    for i in 0..<(sources.map(\.count).max() ?? 0) {
      for source in sources where i < source.count { items.append(source[i]) }
    }
    items += errors.map { Item(id: $0, title: $0, text: nil, isError: true) }
    if items.isEmpty, pending == 0 { items = [Item(id: "empty", title: "No results", isError: true)] }
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
    cell.preview.load(item.thumbnail ?? item.url, text: item.url == nil ? (item.text ?? item.title) : nil)
    cell.accessibilityLabel = item.isCopied ? "Copied \(item.title). Add keywords" : item.title
    cell.accessibilityIdentifier = "keyboard.result.\(indexPath.item)"
    cell.accessibilityHint = item.text != nil ? "Insert text" : "Copy, then paste into your message"
    cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: item.attribution) { _ in true }]
    cell.showFeedback(item.id == loadingID ? "Copying…" : item.id == copiedID ? "Copied ✓" : item.isCopied ? "Add keywords" : nil)
    return cell
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
        let data = try Data(contentsOf: local, options: .mappedIfSafe)
        guard !Task.isCancelled, let self else { return }
        guard data.count <= 8 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else { throw URLError(.cannotDecodeContentData) }
        UIPasteboard.general.setData(data, forPasteboardType: type as String)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(item.gif ? "gif" : "png")
        try data.write(to: file)
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
    tagging = true; previousQuery = query
    layoutCopiedPreview()
    timer?.invalidate(); generation += 1; tasks.forEach { $0.cancel() }; activity.stopAnimating()
    collection.isHidden = true; focusedPreview.isHidden = false; save.isHidden = false
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
    searchField.placeholder = "Search · Powered by GIPHY"
    collection.isHidden = false; focusedPreview.isHidden = true; save.isHidden = true
    focusedPreview.reset()
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
