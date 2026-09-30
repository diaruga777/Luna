import ImageIO
import LunaKeyboardCore
import LunaStorage
import UIKit
import UniformTypeIdentifiers

final class KeyboardToolsPanel: UIView, UITableViewDataSource, UITableViewDelegate {
  var onText: ((String) -> Void)?
  var onStyle: ((TextStyle) -> Void)?
  var onMedia: ((KeyboardShortcut) -> Void)?
  var onClose: (() -> Void)?
  private let catalog: KeyboardCatalog
  private let store: KeyboardStore?
  private let fullAccess: Bool
  private let segments = UISegmentedControl(items: ["Emoji", "Saved", "GIFs", "Images", "Styles"])
  private let searchLabel = UILabel()
  private let table = UITableView(frame: .zero, style: .plain)
  private let close = UIButton(type: .system)
  private var text = ""
  private struct Item {
    var title: String
    var subtitle: String = ""
    var text: String?
    var shortcut: KeyboardShortcut?
    var style: TextStyle?
    var remote: URL?
    var thumb: URL?
  }
  private var items: [Item] = []
  private var searchTask: Task<Void, Never>?
  private var copyTask: Task<Void, Never>?
  private var timer: Timer?
  private var generation = 0
  init(catalog: KeyboardCatalog, store: KeyboardStore?, fullAccess: Bool, styles: Bool) {
    self.catalog = catalog
    self.store = store
    self.fullAccess = fullAccess
    super.init(frame: .zero)
    backgroundColor = .secondarySystemBackground
    [segments, searchLabel, table, close].forEach(addSubview)
    segments.selectedSegmentIndex = styles ? 4 : 0
    segments.addAction(UIAction { [weak self] _ in self?.searchNow() }, for: .valueChanged)
    searchLabel.font = .systemFont(ofSize: 13)
    searchLabel.textColor = .secondaryLabel
    close.setTitle("Done", for: .normal)
    close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 48
    table.keyboardDismissMode = .none
    table.register(MediaRow.self, forCellReuseIdentifier: "row")
    searchNow()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  deinit {
    searchTask?.cancel()
    copyTask?.cancel()
    timer?.invalidate()
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    segments.frame = CGRect(x: 5, y: 2, width: bounds.width - 10, height: 30)
    searchLabel.frame = CGRect(x: 10, y: 34, width: bounds.width - 70, height: 24)
    close.frame = CGRect(x: bounds.width - 58, y: 32, width: 55, height: 28)
    table.frame = CGRect(x: 0, y: 60, width: bounds.width, height: max(0, bounds.height - 60))
  }
  func appendSearch(_ value: String) {
    text += value
    schedule()
  }
  func deleteSearch() {
    if !text.isEmpty { text.removeLast() }
    schedule()
  }
  private func schedule() {
    timer?.invalidate()
    searchLabel.text = "Search: " + text
    timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
      self?.searchNow()
    }
  }
  func searchNow() {
    searchTask?.cancel()
    generation += 1
    searchLabel.text = text.isEmpty ? "Type on the keyboard to search" : "Search: " + text
    switch segments.selectedSegmentIndex {
    case 0:
      items = catalog.browseGlyphs(query: text).map {
        Item(title: $0.text, subtitle: $0.name, text: $0.text)
      }
    case 1:
      items = ((try? store?.shortcuts(limit: 100)) ?? []).filter {
        text.isEmpty || $0.keywords.contains { $0.localizedCaseInsensitiveContains(text) }
          || $0.text.localizedCaseInsensitiveContains(text)
      }.map {
        Item(
          title: $0.text, subtitle: $0.keywords.joined(separator: ", "),
          text: $0.kind == "text" ? $0.text : nil, shortcut: $0.kind == "text" ? nil : $0)
      }
      if text.isEmpty {
        items += [
          Item(
            title: "Dramatic chipmunk",
            shortcut: .init(keywords: ["dramatic"], text: "dramatic_chipmunk", kind: "gif")),
          Item(title: "Wat", shortcut: .init(keywords: ["wat"], text: "wat", kind: "image")),
        ]
        items += ((try? store?.recentLinks(limit: 30)) ?? []).map {
          Item(title: $0.title, subtitle: $0.url, text: $0.url)
        }
      }
    case 4:
      items = TextStyle.allCases.filter {
        text.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(text)
      }.map { Item(title: $0.style($0.rawValue), style: $0) }
    default:
      items = []
      guard fullAccess else {
        searchLabel.text = "Enable Full Access for media search."
        table.reloadData()
        return
      }
      guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
        table.reloadData()
        return
      }
      let query = text
      let gifs = segments.selectedSegmentIndex == 2
      let gen = generation
      searchLabel.text = "Searching…"
      searchTask = Task { [weak self] in
        do {
          let found = try await KeyboardMediaSearch.search(query, gifs: gifs)
          guard !Task.isCancelled, let self, self.generation == gen else { return }
          self.items = found.map {
            Item(
              title: $0.title,
              subtitle: gifs ? "GIPHY · tap to copy" : "Image search · tap to copy",
              remote: $0.url, thumb: $0.thumbnail)
          }
          self.searchLabel.text = found.isEmpty ? "No results" : "Search: " + query
          self.table.reloadData()
        } catch {
          guard !Task.isCancelled, let self, self.generation == gen else { return }
          self.searchLabel.text = "Search unavailable. Try again later."
        }
      }
    }
    table.reloadData()
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    items.count
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! MediaRow
    let item = items[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = item.title
    content.secondaryText = item.subtitle
    content.textProperties.numberOfLines = 1
    content.secondaryTextProperties.numberOfLines = 1
    cell.contentConfiguration = content
    cell.load(item.thumb)
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let item = items[indexPath.row]
    if let text = item.text {
      onText?(text)
    } else if let style = item.style {
      onStyle?(style)
    } else if let shortcut = item.shortcut {
      onMedia?(shortcut)
    } else if let remote = item.remote {
      copyTask?.cancel()
      searchLabel.text = "Copying…"
      let gif = segments.selectedSegmentIndex == 2
      copyTask = Task { [weak self] in
        do {
          let url = try await KeyboardMediaSearch.download(remote, maxBytes: 8 * 1024 * 1024)
          defer { try? FileManager.default.removeItem(at: url) }
          guard !Task.isCancelled, let self else { return }
          let data = try Data(contentsOf: url, options: .mappedIfSafe)
          UIPasteboard.general.setData(
            data, forPasteboardType: gif ? UTType.gif.identifier : UTType.image.identifier)
          self.searchLabel.text = "Copied. Touch and hold in your message, then Paste."
        } catch {
          if !Task.isCancelled { self?.searchLabel.text = "Couldn’t copy this item (8 MB limit)." }
        }
      }
    }
  }
}

private final class MediaRow: UITableViewCell {
  private var task: Task<Void, Never>?
  override func prepareForReuse() {
    super.prepareForReuse()
    task?.cancel()
    task = nil
  }
  deinit { task?.cancel() }
  func load(_ url: URL?) {
    task?.cancel()
    guard let url else { return }
    task = Task { [weak self] in
      guard let local = try? await KeyboardMediaSearch.download(url, maxBytes: 1024 * 1024) else {
        return
      }
      defer { try? FileManager.default.removeItem(at: local) }
      guard !Task.isCancelled, let self,
        let source = CGImageSourceCreateWithURL(local as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { return }
      guard var config = self.contentConfiguration as? UIListContentConfiguration else { return }
      config.image = UIImage(cgImage: image)
      config.imageProperties.maximumSize = CGSize(width: 48, height: 40)
      self.contentConfiguration = config
    }
  }
}

private enum KeyboardMediaSearch {
  struct Result {
    let title: String
    let url: URL
    let thumbnail: URL?
  }
  static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.httpMaximumConnectionsPerHost = 3
    config.timeoutIntervalForRequest = 15
    return URLSession(configuration: config)
  }()
  static func search(_ query: String, gifs: Bool) async throws -> [Result] {
    var components = URLComponents(
      string: gifs
        ? "https://api.giphy.com/v1/gifs/search" : "https://api.qwant.com/v3/search/images")!
    components.queryItems = [
      .init(name: "q", value: query), .init(name: gifs ? "limit" : "count", value: "24"),
    ]
    if gifs {
      components.queryItems?.append(
        .init(name: "api_key", value: KeyboardServiceConfiguration.giphyKey))
      components.queryItems?.append(.init(name: "rating", value: "pg-13"))
    } else {
      components.queryItems?.append(.init(name: "t", value: "images"))
      components.queryItems?.append(.init(name: "locale", value: "en_us"))
      components.queryItems?.append(.init(name: "offset", value: "0"))
    }
    let (data, response) = try await session.data(from: components.url!)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.count < 2 * 1024 * 1024
    else {
      if !gifs { return try await openverse(query) }
      throw URLError(.badServerResponse)
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    if gifs {
      return (object["data"] as? [[String: Any]] ?? []).compactMap { value in
        guard let images = value["images"] as? [String: [String: Any]],
          let original = images["fixed_height"], let text = original["url"] as? String,
          let url = URL(string: text)
        else { return nil }
        return Result(
          title: value["title"] as? String ?? "GIF", url: url,
          thumbnail: (images["fixed_height_still"]?["url"] as? String).flatMap(URL.init(string:)))
      }
    }
    let dataObject = object["data"] as? [String: Any]
    let result = dataObject?["result"] as? [String: Any]
    return (result?["items"] as? [[String: Any]] ?? []).compactMap { value in
      guard let text = value["media"] as? String, let url = URL(string: text), url.scheme == "https"
      else { return nil }
      return Result(
        title: value["title"] as? String ?? "Image", url: url,
        thumbnail: (value["thumbnail"] as? String).flatMap(URL.init(string:)))
    }
  }
  // The legacy Qwant API may reject anonymous requests. Keep image search
  // usable with a public-domain/CC0 Openverse fallback when that happens.
  static func openverse(_ query: String) async throws -> [Result] {
    var url = URLComponents(string: "https://api.openverse.org/v1/images/")!
    url.queryItems = [
      .init(name: "q", value: query), .init(name: "page_size", value: "24"),
      .init(name: "license", value: "cc0,pdm"),
    ]
    let (data, response) = try await session.data(from: url.url!)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.count < 2 * 1024 * 1024
    else { throw URLError(.badServerResponse) }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return (object["results"] as? [[String: Any]] ?? []).compactMap { value in
      guard let path = value["url"] as? String, let url = URL(string: path), url.scheme == "https"
      else { return nil }
      return Result(
        title: value["title"] as? String ?? "Image", url: url,
        thumbnail: (value["thumbnail"] as? String).flatMap(URL.init(string:)))
    }
  }

  static func download(_ url: URL, maxBytes: Int) async throws -> URL {
    guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
    let (local, response) = try await session.download(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      (try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= maxBytes
    else {
      try? FileManager.default.removeItem(at: local)
      throw URLError(.dataLengthExceedsMaximum)
    }
    return local
  }
}
