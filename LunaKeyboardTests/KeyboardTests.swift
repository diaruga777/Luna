import LunaModels
import SQLite3
import UIKit
import XCTest

@testable import LunaKeyboardCore
@testable import LunaKeyboardUI
@testable import LunaStorage

final class KeyboardTests: XCTestCase {
  private var directory: URL!
  private var saves: SavesStore!
  private var store: KeyboardStore!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    saves = SavesStore(containerURL: directory)
    store = KeyboardStore(saves: saves, containerURL: directory)
  }
  override func tearDownWithError() throws {
    store = nil
    saves = nil
    try FileManager.default.removeItem(at: directory)
  }
  func testAdjacentSubstitutionsRankFirst() {
    XCTAssertLessThan(
      KeyboardRanking.distance("gell", "hell"), KeyboardRanking.distance("gell", "sell"))
    XCTAssertEqual(KeyboardRanking.rank(["sell", "hell"], for: "gell"), ["hell", "sell"])
  }
  func testContextUsesUTF16() {
    let c = KeyboardTextContext(before: "👨‍👩‍👧‍👦 café hel")
    XCTAssertEqual((c.text as NSString).substring(with: c.range), "hel")
    XCTAssertEqual(c.word, "hel")
    XCTAssertGreaterThan(c.range.location, 8)
  }
  func testContextIsBounded() {
    let c = KeyboardTextContext(before: String(repeating: "hello ", count: 10000) + "world")
    XCTAssertLessThanOrEqual(c.text.count, 256)
    XCTAssertEqual(c.word, "world")
  }
  func testEmojiAndAsciiDefaults() {
    let catalog = KeyboardCatalog()
    XCTAssertTrue(catalog.glyphs(for: "shrug").contains { $0.text == "¯\\_(ツ)_/¯" })
    XCTAssertFalse(catalog.glyphs(for: "flag").isEmpty)
    XCTAssertFalse(catalog.glyphs(for: "skin").isEmpty)
    XCTAssertFalse(catalog.glyphs(for: "grinning").isEmpty)
  }
  func testEveryEmojiHasKeywords() throws {
    let url = try XCTUnwrap(KeyboardResources.url("KeyboardCatalog", extension: "sqlite"))
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_close(db) }
    var s: OpaquePointer?
    sqlite3_prepare_v2(
      db,
      "SELECT count(*) FROM glyphs WHERE NOT EXISTS (SELECT 1 FROM keywords WHERE glyph_id=glyphs.id)",
      -1, &s, nil)
    defer { sqlite3_finalize(s) }
    XCTAssertEqual(sqlite3_step(s), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_int(s, 0), 0)
  }
  func testStylesRoundTrip() {
    for style in TextStyle.allCases where ![.boxed, .inverseBoxed, .ransom].contains(style) {
      let styled = style.style("Hello 123")
      XCTAssertEqual(styled.styleErased, "Hello 123", style.rawValue)
    }
  }
  func testRandomStyleDoesNotRecurse() {
    for _ in 0..<500 { XCTAssertFalse(TextStyle.ransom.style("a").isEmpty) }
  }
  func testPreferencesAcrossConnections() throws {
    let other = KeyboardStore(saves: SavesStore(containerURL: directory), containerURL: directory)
    try store.setPreference("sound", value: "false")
    XCTAssertEqual(try other.preferences()["sound"], "false")
    try other.setPreference("language", value: "es")
    XCTAssertEqual(try store.preferences()["language"], "es")
  }
  func testShortcutUpdateAndDelete() throws {
    var entry = KeyboardShortcut(keywords: ["BRB", "be right"], text: "Be right back")
    try store.save(entry)
    XCTAssertEqual(try store.shortcuts(matching: "brb").first?.text, "Be right back")
    entry.keywords = ["later"]
    entry.text = "See you"
    try store.save(entry)
    XCTAssertTrue(try store.shortcuts(matching: "brb").isEmpty)
    XCTAssertEqual(try store.shortcuts(matching: "later").count, 1)
    try store.delete(id: entry.id)
    XCTAssertTrue(try store.shortcuts().isEmpty)
  }
  func testMediaOwnershipReapsReplacedAndDeletedFiles() throws {
    let source = directory.appendingPathComponent("input.gif")
    try Data([1, 2, 3]).write(to: source)
    let entry = KeyboardShortcut(keywords: ["test"], text: "test", kind: "gif")
    try store.save(entry, importing: source)
    let saved = try XCTUnwrap(store.shortcuts().first)
    let old = try XCTUnwrap(store.fileURL(for: saved))
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    try store.save(saved, importing: source)
    let updated = try XCTUnwrap(store.shortcuts().first)
    let current = try XCTUnwrap(store.fileURL(for: updated))
    XCTAssertNotEqual(old, current)
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    try store.delete(id: entry.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }
  func testForgedFileClaimRejected() throws {
    XCTAssertThrowsError(
      try store.save(
        .init(keywords: ["bad"], text: "bad", kind: "image", relativePath: "../outside.png")))
  }
  func testDictionaryIsLiteralAndLanguageScoped() throws {
    try store.setWord("Luna", language: "en", included: true)
    XCTAssertEqual(try store.dictionary(language: "en", prefix: "lu"), ["Luna"])
    XCTAssertTrue(try store.dictionary(language: "es").isEmpty)
    try store.setWord("Luna", language: "en", included: false)
    XCTAssertTrue(try store.dictionary(language: "en").isEmpty)
  }
  func testRecentLinksBoundedAndSorted() throws {
    for i in 0..<20 { _ = saves.add(urlString: "https://example.com/\(i)") }
    let links = try store.recentLinks(limit: 3)
    XCTAssertEqual(links.count, 3)
    XCTAssertTrue(links[0].url.hasSuffix("/19"))
    XCTAssertTrue(links[1].url.hasSuffix("/18"))
  }
  func testTypingSuggestionsSuppressLunaFallback() throws {
    _ = saves.add(urlString: "https://example.com/saved")
    let engine = KeyboardPrediction()
    let p = KeyboardPreferences(values: ["autocomplete": "false", "spellcheck": "false"])
    XCTAssertEqual(engine.suggestions(before: "", preferences: p, store: store).first?.kind, .link)
    XCTAssertFalse(
      engine.suggestions(before: "shrug", preferences: p, store: store).contains {
        $0.kind == .link
      })
    XCTAssertTrue(engine.suggestions(before: "", preferences: p, store: nil).isEmpty)
  }
  func testPhraseShortcutPrediction() throws {
    try store.save(.init(keywords: ["see you"], text: "See you tomorrow"))
    let output = KeyboardPrediction().suggestions(
      before: "I will see you",
      preferences: .init(values: ["autocomplete": "false", "spellcheck": "false"]), store: store)
    XCTAssertEqual(output.first?.replacing, "see you")
    XCTAssertEqual(output.first?.text, "See you tomorrow")
  }
  func testSwipeDecodesHelloWithCrossedKeys() {
    let centers = Dictionary(
      uniqueKeysWithValues: Array("qwertyuiopasdfghjklzxcvbnm").compactMap { c in
        KeyboardRanking.center(c).map { (c, CGPoint(x: $0.x * 30, y: $0.y * 45)) }
      })
    let route = Array("hello").compactMap { centers[$0] }
    let samples = KeyboardSwipeDecoder.resample(route, count: 48).map { p in
      SwipeSample(
        point: p,
        letter: centers.min {
          hypot($0.value.x - p.x, $0.value.y - p.y) < hypot($1.value.x - p.x, $1.value.y - p.y)
        }!.key)
    }
    XCTAssertEqual(
      KeyboardSwipeDecoder.decode(
        samples, catalog: KeyboardCatalog(), language: "en", centers: centers
      ).first, "hello")
  }
  @MainActor func testSurfaceReleasesWithoutRetainCycle() {
    weak var weakSurface: KeyboardSurface?
    autoreleasepool {
      let surface = KeyboardSurface()
      weakSurface = surface
      surface.refresh()
      surface.releaseMemory()
    }
    XCTAssertNil(weakSurface)
  }
  @MainActor func testSuggestionViewsStayBoundedWhileTyping() {
    let surface = KeyboardSurface()
    surface.frame = CGRect(x: 0, y: 0, width: 393, height: 264)
    var text = ""
    surface.before = { text }
    surface.insert = { text += $0 }
    surface.delete = { if !text.isEmpty { text.removeLast() } }
    for _ in 0..<2000 {
      surface.key("a")
      surface.key("delete")
    }
    surface.releaseMemory()
    XCTAssertLessThan(surface.subviews.count, 10)
  }

  func testAbandonedMediaSweepKeepsLiveHoldings() throws {
    let source = directory.appendingPathComponent("source.gif")
    try Data([1]).write(to: source)
    try store.save(.init(keywords: ["live"], text: "live", kind: "gif"), importing: source)
    let live = try XCTUnwrap(store.fileURL(for: XCTUnwrap(store.shortcuts().first)))
    let orphan = directory.appendingPathComponent("KeyboardMedia/" + UUID().uuidString + ".gif")
    try Data([2]).write(to: orphan)
    try store.reapAbandonedMedia()
    XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
  }
  func testVideosUseTheSameRecencyOrderAndDisappearOnArchive() throws {
    let item = saves.add(urlString: "https://example.com/video")
    var media = SavedMediaItem(
      id: item.id, sourceURLString: item.urlString, title: "My video", dateSaved: Date(),
      kind: .video, storageState: .undownloaded, thumbnailFileName: nil)
    try saves.replaceMediaItems([media])
    XCTAssertEqual(try store.recentLinks().first?.isVideo, true)
    media.archivedAt = Date()
    try saves.replaceMediaItems([media])
    XCTAssertTrue(try store.recentLinks().isEmpty)
  }
  func testTrailingSpaceDoesNotOfferUnusableEmojiReplacement() {
    let p = KeyboardPreferences(values: ["autocomplete": "false", "spellcheck": "false"])
    XCTAssertTrue(
      KeyboardPrediction().suggestions(before: "shrug ", preferences: p, store: nil).isEmpty)
  }
  func testStyledWordUsesOriginalReplacement() {
    let word = TextStyle.bold.style("brb")
    let p = KeyboardPreferences(values: ["autocomplete": "false", "spellcheck": "false"])
    let result = KeyboardPrediction().suggestions(
      before: word, preferences: p, store: nil, lexicon: ["brb": "be right back"])
    XCTAssertEqual(result.first?.replacing, word)
  }
}

extension KeyboardTests {
  @MainActor private func editor(_ initial: String = "", clock: @escaping () -> TimeInterval = { 100 }) -> (KeyboardSurface, () -> String) {
    let surface = KeyboardSurface()
    var text = initial
    surface.before = { text }
    surface.insert = { text += $0 }
    surface.delete = { if !text.isEmpty { text.removeLast() } }
    surface.now = clock
    surface.preferences = .init(values: ["autoCapitalize": "false", "sound": "false", "spellcheck": "false", "autocomplete": "false"])
    surface.lexicon = ["teh": "the"]
    surface.refresh()
    return (surface, { text })
  }
  @MainActor func testRejectedCorrectionDoesNotReapplyAndPunctuationIsPreserved() {
    let (s, text) = editor()
    for key in ["t", "e", "h", " "] { s.key(key) }
    XCTAssertEqual(text(), "the ")
    s.key("delete")
    XCTAssertEqual(text(), "teh")
    s.key(" ")
    XCTAssertEqual(text(), "teh ")
    s.releaseMemory()
    let (p, punctuated) = editor()
    for key in ["t", "e", "h", " ", "?"] { p.key(key) }
    XCTAssertEqual(punctuated(), "the?")
    p.key("delete")
    XCTAssertEqual(punctuated(), "teh?")
    p.releaseMemory()
  }
  @MainActor func testDelayedBackspaceDeletesAndExpiredCandidateDoesNotApply() {
    var time: TimeInterval = 100
    let (s, text) = editor(clock: { time })
    for key in ["t", "e", "h", " "] { s.key(key) }
    time += 1.1
    s.key("delete")
    XCTAssertEqual(text(), "the")
    s.releaseMemory()
    let (p, pending) = editor(clock: { time })
    for key in ["t", "e", "h"] { p.key(key) }
    time += 3
    p.key(" ")
    XCTAssertEqual(pending(), "teh ")
    p.releaseMemory()
  }
  @MainActor func testQuotesCanBeTypedRepeatedlyAndURLTextStaysLiteral() {
    let (s, text) = editor()
    for key in ["\"", "h", "i", "\"", " ", "\"", "o", "k", "\""] { s.key(key) }
    XCTAssertEqual(text(), "“hi” “ok”")
    s.releaseMemory()
    let (u, url) = editor()
    u.fieldAllowsAutocorrect = false
    u.fieldAllowsSmartPunctuation = false
    for key in ["t", "e", "h", " ", "?", "'"] { u.key(key) }
    XCTAssertEqual(url(), "teh ?'")
    u.releaseMemory()
  }
  func testPunctuationIsNotPartOfWord() {
    XCTAssertEqual(KeyboardTextContext(before: "…hello").word, "hello")
    XCTAssertEqual(KeyboardTextContext(before: "hello…").word, "")
    XCTAssertEqual(KeyboardTextContext(before: "“hello").word, "hello")
    XCTAssertEqual(KeyboardTextContext(before: "hello’").word, "")
    XCTAssertEqual(KeyboardTextContext(before: "don't").word, "don't")
  }
  @MainActor func testDeleteDragRestoresTextAndStopsAtBounds() {
    let (s, text) = editor("dragonloser")
    s.updateDeleteDrag(5)
    XCTAssertEqual(text(), "dragon")
    s.updateDeleteDrag(2)
    XCTAssertEqual(text(), "dragonlos")
    s.updateDeleteDrag(0)
    XCTAssertEqual(text(), "dragonloser")
    s.updateDeleteDrag(100)
    XCTAssertEqual(text(), "")
    s.finishDeleteDrag()
    s.updateDeleteDrag(100)
    XCTAssertEqual(text(), "")
    s.releaseMemory()
  }
  @MainActor func testPadKeysAndAccessibleStyledLetters() {
    let board = KeyboardBoardView(frame: CGRect(x: 0, y: 0, width: 1024, height: 340))
    board.isPad = true
    board.textStyle = .bold
    board.layoutIfNeeded()
    let names = (board.accessibilityElements as? [UIAccessibilityElement])?.compactMap(\.accessibilityLabel) ?? []
    XCTAssertTrue(names.contains("Tab"))
    XCTAssertTrue(names.contains("Hide keyboard"))
    XCTAssertTrue(names.contains("Delete"))
    XCTAssertTrue(names.contains("q"))
    XCTAssertEqual(board.firstAlternative(for: "q"), "1")
    XCTAssertEqual(board.firstAlternative(for: "a"), "@")
  }
}

extension KeyboardTests {
  func testLookupOnlyAndCosmeticShortcuts() throws {
    try store.save(.init(keywords: ["quiet"], text: "secret phrase", suggestWhileTyping: false))
    try store.save(.init(keywords: ["shrug"], text: "¯\\_(ツ)_/¯", isCosmetic: true))
    XCTAssertEqual(try store.shortcuts(matching: "quiet").count, 1)
    XCTAssertTrue(try store.shortcuts(matching: "quiet", forTyping: true).isEmpty)
    let results = KeyboardPrediction().suggestions(before: "shrug", preferences: .init(), store: store)
    XCTAssertEqual(results.first?.kind, .shortcut)
    XCTAssertEqual(results.first?.autoApply, false)
  }
  func testPortableShortcutRoundTripWithMediaAndFlags() throws {
    let source = directory.appendingPathComponent("input.gif")
    try Data([1, 2, 3]).write(to: source)
    let entry = KeyboardShortcut(keywords: ["wave"], text: "Wave", kind: "gif", suggestWhileTyping: false, isCosmetic: true)
    try store.save(entry, importing: source)
    let saved = try XCTUnwrap(store.shortcuts().first)
    let archive = try KeyboardShortcutArchive(shortcut: saved, store: store)
    let file = directory.appendingPathComponent("shared.lunakeyboard")
    try JSONEncoder().encode(archive).write(to: file)
    try KeyboardShortcutArchive.read(file).save(to: store)
    let copies = try store.shortcuts()
    XCTAssertEqual(copies.count, 2)
    XCTAssertNotEqual(copies[0].id, copies[1].id)
    XCTAssertNotEqual(copies[0].relativePath, copies[1].relativePath)
    XCTAssertTrue(copies.allSatisfy { !$0.suggestWhileTyping && $0.isCosmetic })
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(for: copies[0]))), Data([1, 2, 3]))
  }
  func testCorruptSharedShortcutRejected() throws {
    let file = directory.appendingPathComponent("bad.lunakeyboard")
    try Data(#"{"version":99,"keywords":["a"],"text":"bad","kind":"text","suggestWhileTyping":true,"isCosmetic":false}"#.utf8).write(to: file)
    XCTAssertThrowsError(try KeyboardShortcutArchive.read(file))
  }
  func testMissingMediaCanBeRepairedOrRemoved() throws {
    let source = directory.appendingPathComponent("input.gif")
    try Data([1]).write(to: source)
    try store.save(.init(keywords: ["photo"], text: "Photo", kind: "gif"), importing: source)
    let entry = try XCTUnwrap(store.shortcuts().first)
    let url = try XCTUnwrap(store.fileURL(for: entry))
    try FileManager.default.removeItem(at: url)
    XCTAssertTrue(store.mediaIsMissing(entry))
    let p = KeyboardPreferences(values: ["autocomplete": "false", "spellcheck": "false"])
    XCTAssertFalse(KeyboardPrediction().suggestions(before: "photo", preferences: p, store: store).contains { $0.kind == .media })
    try store.save(entry, importing: source)
    let repaired = try XCTUnwrap(store.shortcuts().first)
    XCTAssertFalse(store.mediaIsMissing(repaired))
    try FileManager.default.removeItem(at: XCTUnwrap(store.fileURL(for: repaired)))
    XCTAssertEqual(try store.removeMissingMedia(), 1)
    XCTAssertTrue(try store.shortcuts().isEmpty)
  }
  func testSearchCacheExpiresAndHasBoundedEntries() throws {
    for i in 0..<25 { try store.cacheMediaSearch("query\(i)", payload: "[]") }
    XCTAssertNil(try store.cachedMediaSearch("query0"))
    XCTAssertEqual(try store.cachedMediaSearch("query24"), "[]")
    XCTAssertNil(try store.cachedMediaSearch("query24", maxAge: -1))
  }
}
