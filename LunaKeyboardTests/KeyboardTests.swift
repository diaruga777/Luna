import LunaAppConfig
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
    for style in TextStyle.allCases where ![.boxed, .inverseBoxed, .ransom, .spongeBob].contains(style) {
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
    XCTAssertEqual(text(), "teh ")
    s.key(" ")
    XCTAssertEqual(text(), "teh  ")
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

extension KeyboardTests {
  @MainActor func testDisplacedAutomaticCapitalizationAndPreservedManualCapitalization() {
    let s = KeyboardSurface()
    var text = ""
    var cursor = 0
    s.before = { String(text.prefix(cursor)) }
    s.after = { String(text.dropFirst(cursor)) }
    s.insert = { value in text.insert(contentsOf: value, at: text.index(text.startIndex, offsetBy: cursor)); cursor += value.count }
    s.delete = { if cursor > 0 { cursor -= 1; text.remove(at: text.index(text.startIndex, offsetBy: cursor)) } }
    s.moveCursor = { cursor = max(0, min(text.count, cursor + $0)) }
    s.preferences = .init(values: ["sound": "false", "autocorrect": "false"])
    s.refresh()
    for key in ["h", "e", "l", "l", "o"] { s.key(key) }
    XCTAssertEqual(text, "Hello")
    cursor = 0; s.refresh()
    for key in ["w", "e", "l", "l", " "] { s.key(key) }
    XCTAssertEqual(text, "Well hello")
    XCTAssertEqual(cursor, 5)
    s.releaseMemory()
  }
  @MainActor func testThemePreferencesAndEmojiSpeech() throws {
    try store.setPreference("theme", value: "Ocean")
    let s = KeyboardSurface(); s.store = store; s.reloadSettings()
    XCTAssertEqual(s.board.theme, .ocean)
    let suggestion = KeyboardPrediction().suggestions(before: "shrug", preferences: .init(), store: nil).first { $0.kind == .emoji }
    XCTAssertFalse(try XCTUnwrap(suggestion).accessibilityLabel.contains("¯"))
    s.releaseMemory()
  }
}

extension KeyboardTests {
  @MainActor func testCorrectionAppliesBeforeKeyboardSend() {
    let (s, text) = editor()
    for key in ["t", "e", "h", "return"] { s.key(key) }
    XCTAssertEqual(text(), "the\n")
    s.releaseMemory()
  }
}

@testable import LunaKeyboard

extension KeyboardTests {
  @MainActor func testQuestDemonstrationsCompleteAllFourLessons() async throws {
    let controller = KeyboardTutorialController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    controller.view.layoutIfNeeded()
    controller.surface.layoutIfNeeded()
    controller.surface.board.layoutIfNeeded()
    func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let buttons = descendants(controller.view).compactMap { $0 as? UIButton }
    let demo = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "keyboard.tutorial.demo" })
    let next = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "keyboard.tutorial.nextLesson" })
    for step in 0..<4 {
      demo.sendActions(for: .touchUpInside)
      try await Task.sleep(nanoseconds: 2_400_000_000)
      XCTAssertTrue(next.isEnabled, "Lesson \(step + 1): \(controller.editor.text ?? "")")
      if step < 3 { next.sendActions(for: .touchUpInside) }
    }
    controller.surface.releaseMemory()
  }
}

extension KeyboardTests {
  func testOrdinalsAndDeliberateRepeatsNeverAutocorrect() {
    let prediction = KeyboardPrediction()
    for word in ["1st", "21st", "42nd", "3rd", "4th", "babyyyyyy", "nooooo", "aAaA"] {
      XCTAssertEqual(KeyboardTextContext(before: word).word, word)
      let results = prediction.suggestions(before: word, preferences: .init(), store: nil,
        lexicon: [word.lowercased(): "replacement", "st": "street"])
      XCTAssertFalse(results.contains(where: \.autoApply), word)
    }
    XCTAssertFalse(KeyboardEditing.protectsFromCorrection("baby"))
  }
  @MainActor func testCorrectionUndoRetainsMultipleNonlettersAndFollowingSpace() {
    for suffix in [[" "], ["?", "!", " "], [".", " ", "\""], [")", "]", " "], [" ", " "]] {
      let (surface, text) = editor()
      var clock: TimeInterval = 10
      surface.now = { clock }
      // Slow repeated spaces remain document input; fast ones now invoke search.
      for key in ["t", "e", "h"] + suffix { clock += 0.41; surface.key(key) }
      XCTAssertTrue(text().hasPrefix("the"))
      let ending = String(text().dropFirst(3))
      surface.key("delete")
      XCTAssertEqual(text(), "teh" + ending)
      surface.releaseMemory()
    }
  }
  @MainActor func testCorrectionSuffixStillTrackedWithoutSmartPunctuation() {
    let (surface, text) = editor()
    surface.fieldAllowsSmartPunctuation = false
    for key in ["t", "e", "h", " ", "?", "!", " "] { surface.key(key) }
    surface.key("delete")
    XCTAssertEqual(text(), "teh ?! ")
    surface.releaseMemory()
  }
  @MainActor func testNewWordInvalidatesUndo() {
    let (surface, text) = editor()
    for key in ["t", "e", "h", "?", " ", "a", "delete"] { surface.key(key) }
    XCTAssertEqual(text(), "the? ")
    surface.releaseMemory()
  }
  func testAbbreviationsDoNotStartSentences() {
    for text in ["e.g. ", "Try e.g. ", "i.e. ", "Dr. ", "vs. "] {
      XCTAssertFalse(KeyboardEditing.startsSentence(after: text), text)
    }
    for text in ["", "Done. ", "Done! ", "Next\n", "leg. "] {
      XCTAssertTrue(KeyboardEditing.startsSentence(after: text), text)
    }
  }
  @MainActor func testTypingAfterEGStaysLowercase() {
    let (surface, text) = editor("Try e.g.")
    surface.preferences.values["autoCapitalize"] = "true"
    surface.key(" "); surface.key("a")
    XCTAssertEqual(text(), "Try e.g. a")
    surface.releaseMemory()
  }
  func testStyleSuggestionsDisappearAfterApplicationAndQuotesAreNotNoOps() throws {
    let prediction = KeyboardPrediction()
    let preferences = KeyboardPreferences(values: ["autocomplete": "false", "spellcheck": "false"])
    let style = try XCTUnwrap(prediction.suggestions(before: "*hello*", preferences: preferences, store: nil).first { $0.kind == .style })
    XCTAssertEqual(style.text, TextStyle.bold.style("hello"))
    XCTAssertFalse(prediction.suggestions(before: style.text, preferences: preferences, store: nil).contains { $0.kind == .style })
    for text in ["\"hello\"", "'hello'"] {
      XCTAssertFalse(prediction.suggestions(before: text, preferences: preferences, store: nil).contains { $0.kind == .style })
    }
  }
  func testCalculatorPrecedenceParenthesesAndInvalidInput() {
    let cases = ["2+3*4": "14", "(2+3)*4=": "20", "-2.5×4": "-10", "100*20%": "20", "8÷2": "4", "0.1+0.2": "0.3", "Total 2 + 3": "5"]
    for (expression, result) in cases {
      let suggestion = KeyboardCalculator.suggestion(before: expression)
      XCTAssertEqual(suggestion?.text, result, expression)
      XCTAssertEqual(suggestion?.autoApply, false)
    }
    XCTAssertEqual(KeyboardCalculator.suggestion(before: "Total 2 + 3")?.replacing, "2 + 3")
    for expression in ["1st", "21st", "42", "1/0", "(2+3", "2+", "1 2+3", "name2+3", "https://1+2", "pow(2,3)", String(repeating: "1+", count: 100)] {
      XCTAssertNil(KeyboardCalculator.suggestion(before: expression), expression)
    }
  }
  func testSpongeBobHasNoThreeSameCasesAcrossChunks() {
    var output = ""
    for _ in 0..<100 {
      output += TextStyle.spongeBob.style("Baby ß! ﬃ wow ", preceding: output)
    }
    let letters = Array(output.filter { $0.isLowercase || $0.isUppercase })
    for i in 2..<letters.count {
      XCTAssertFalse(letters[i].isUppercase == letters[i-1].isUppercase && letters[i].isUppercase == letters[i-2].isUppercase)
    }
    XCTAssertEqual(TextStyle.spongeBob.style("c", preceding: "AB "), "c")
    XCTAssertEqual(TextStyle.spongeBob.style("c", preceding: "ab "), "C")
  }
  @MainActor func testSpongeBobTypingAcrossKeystrokes() {
    let (surface, text) = editor()
    surface.board.textStyle = .spongeBob
    for key in "this is a long sentence".map(String.init) { surface.key(key) }
    let letters = Array(text().filter(\.isLetter))
    for i in 2..<letters.count {
      XCTAssertFalse(letters[i].isUppercase == letters[i-1].isUppercase && letters[i].isUppercase == letters[i-2].isUppercase)
    }
    surface.releaseMemory()
  }
  @MainActor func testDashPopupModeAndExitKeepLiteralHyphens() {
    let (surface, text) = editor()
    XCTAssertTrue(surface.board.holdAlternatives(for: "-").contains("Dashes"))
    surface.key("Dashes")
    XCTAssertTrue(surface.board.dashesMode)
    surface.board.textStyle = .bold
    var clock: TimeInterval = 10
    surface.now = { clock }
    for key in ["a", " ", " ", "b"] { clock += 0.41; surface.key(key) }
    XCTAssertEqual(text(), TextStyle.bold.style("a") + "--" + TextStyle.bold.style("b"))
    XCTAssertTrue(surface.board.holdAlternatives(for: "-").contains("Spaces"))
    surface.key("Spaces"); surface.key(" ")
    XCTAssertTrue(text().hasSuffix(" "))
    XCTAssertFalse(surface.board.dashesMode)
    surface.releaseMemory()
  }
  @MainActor private func suggestionButton(_ title: String, surface: KeyboardSurface) async throws -> UIButton {
    surface.refresh()
    try await Task.sleep(nanoseconds: 100_000_000)
    func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    return try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { !$0.isHidden && $0.title(for: .normal) == title })
  }
  @MainActor func testSelectionLearnsAndLongPressRemovalUnlearns() async throws {
    let word = "lunazorbium"
    defer { UITextChecker.unlearnWord(word) }
    let (surface, text) = editor(word)
    surface.store = store
    surface.preferences.values["autocomplete"] = "true"
    let button = try await suggestionButton(word, surface: surface)
    button.sendActions(for: .touchUpInside)
    XCTAssertEqual(text(), word)
    XCTAssertTrue(try store.dictionary(language: "en").contains(word))
    XCTAssertTrue(UITextChecker.hasLearnedWord(word))
    let learned = try await suggestionButton(word, surface: surface)
    let interaction = try XCTUnwrap(learned.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
    XCTAssertNotNil(surface.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero))
    let removal = try XCTUnwrap(learned.accessibilityCustomActions?.first)
    XCTAssertTrue(removal.actionHandler?(removal) == true)
    XCTAssertFalse(try store.dictionary(language: "en").contains(word))
    XCTAssertFalse(UITextChecker.hasLearnedWord(word))
    surface.releaseMemory()
  }
  @MainActor func testCalculatorSuggestionAppliesWithoutEatingPrecedingSpace() async throws {
    let (surface, text) = editor("Total 2 + 3")
    let button = try await suggestionButton("= 5", surface: surface)
    button.sendActions(for: .touchUpInside)
    XCTAssertEqual(text(), "Total 5")
    surface.releaseMemory()
  }
  @MainActor func testPasteSuggestionOnlyInEmptyEditorAndRequiresFullAccess() async throws {
    let (surface, text) = editor()
    surface.hasFullAccess = true
    surface.hasPasteableText = { true }
    surface.refresh()
    try await Task.sleep(nanoseconds: 100_000_000)
    func findPaste(_ view: UIView) -> UIPasteControl? {
      if let paste = view as? UIPasteControl { return paste }
      return view.subviews.compactMap(findPaste).first
    }
    let paste = try XCTUnwrap(findPaste(surface))
    XCTAssertFalse(paste.isHidden)
    surface.hasPasteableText = { false }
    surface.refresh()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(paste.isHidden)
    surface.hasPasteableText = { true }
    surface.paste(itemProviders: [NSItemProvider(object: "hello from paste" as NSString)])
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(text(), "hello from paste")
    XCTAssertTrue(paste.isHidden)
    surface.releaseMemory()
    let (restricted, empty) = editor()
    restricted.paste(itemProviders: [NSItemProvider(object: "private" as NSString)])
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(empty(), "")
    restricted.releaseMemory()
  }
}

extension KeyboardTests {
  @MainActor func testSpongeBobSwipeAlternativeReplacesActualRandomCasing() throws {
    let centers = Dictionary(uniqueKeysWithValues: Array("qwertyuiopasdfghjklzxcvbnm").compactMap { c in
      KeyboardRanking.center(c).map { (c, CGPoint(x: $0.x * 30, y: $0.y * 45)) }
    })
    let samples = Array("hello").map { SwipeSample(point: centers[$0]!, letter: $0) }
    let words = KeyboardSwipeDecoder.decode(samples, catalog: KeyboardCatalog(), language: "en", centers: centers)
    XCTAssertGreaterThan(words.count, 1)
    let (surface, text) = editor("AB ")
    surface.board.textStyle = .spongeBob
    surface.board.onSwipe?(samples, centers)
    func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let alternative = try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { !$0.isHidden && $0.title(for: .normal) == words[1] })
    alternative.sendActions(for: .touchUpInside)
    XCTAssertEqual(text().lowercased(), "ab " + words[1])
    XCTAssertTrue(text().dropFirst(3).first?.isLowercase == true)
    surface.releaseMemory()
  }
  @MainActor func testPasteArrivingAfterTypingIsDiscarded() async throws {
    let (surface, text) = editor()
    surface.hasFullAccess = true
    surface.paste(itemProviders: [NSItemProvider(object: "old clipboard" as NSString)])
    surface.key("a")
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(text(), "a")
    surface.releaseMemory()
  }
}

extension KeyboardTests {
  @MainActor func testSpaceReplacesSelectionWithoutCorrectingAdjacentWord() {
    let controller = KeyboardTryoutController()
    controller.loadViewIfNeeded()
    let surface = controller.surface
    surface.preferences = .init(values: ["autoCapitalize": "false", "sound": "false", "spellcheck": "false", "autocomplete": "false"])
    surface.lexicon = ["teh": "the"]
    controller.editor.text = "tehSELECT end"
    controller.editor.selectedRange = NSRange(location: 3, length: 6)
    surface.refresh()
    surface.key(" ")
    XCTAssertEqual(controller.editor.text, "teh  end")
    surface.releaseMemory()
  }

  @MainActor func testPunctuationReplacesSelectionWithoutDeletingAdjacentSpace() {
    let controller = KeyboardTryoutController()
    controller.loadViewIfNeeded()
    controller.surface.preferences.values["autocorrect"] = "false"
    controller.editor.text = "hello SELECT end"
    controller.editor.selectedRange = NSRange(location: 6, length: 6)
    controller.surface.refresh()
    controller.surface.key("?")
    XCTAssertEqual(controller.editor.text, "hello ? end")
    controller.surface.releaseMemory()
  }

  @MainActor func testStaleSuggestionDoesNotDeleteSelection() async throws {
    let controller = KeyboardTryoutController()
    controller.loadViewIfNeeded()
    let surface = controller.surface
    surface.preferences.values["autoCapitalize"] = "false"
    surface.lexicon = ["teh": "the"]
    controller.editor.text = "tehSELECT end"
    controller.editor.selectedRange = NSRange(location: 3, length: 0)
    let suggestion = try await suggestionButton("the", surface: surface)
    controller.editor.selectedRange = NSRange(location: 3, length: 6)
    suggestion.sendActions(for: .touchUpInside)
    XCTAssertEqual(controller.editor.text, "tehSELECT end")
    surface.releaseMemory()
  }

  @MainActor func testDoubleSpaceSearchWorksWhenProsePunctuationIsDisabled() {
    let (surface, text) = editor("example")
    surface.fieldAllowsSmartPunctuation = false
    surface.key(" "); surface.key(" ")
    XCTAssertEqual(text(), "example")
    XCTAssertTrue(surface.subviews.contains { $0 is KeyboardToolsPanel })
    surface.releaseMemory()
  }

  @MainActor func testUndoSuggestionResetsDoubleSpacePeriod() async throws {
    let (surface, text) = editor()
    for key in ["t", "e", "h", " "] { surface.key(key) }
    let undo = try await suggestionButton("↶ teh", surface: surface)
    undo.sendActions(for: .touchUpInside)
    surface.key(" ")
    XCTAssertEqual(text(), "teh  ")
    surface.releaseMemory()
  }

  @MainActor func testReleaseMemoryEndsDeleteDrag() {
    let (surface, text) = editor("dragonloser")
    surface.updateDeleteDrag(5)
    surface.releaseMemory()
    surface.updateDeleteDrag(0)
    XCTAssertEqual(text(), "dragon")
    surface.releaseMemory()
  }
}

extension KeyboardTests {
  func testSecondaryLanguageDoesNotCorrectValidPrimaryWords() {
    let prediction = KeyboardPrediction()
    let preferences = KeyboardPreferences(values: ["language": "en", "secondaryLanguage": "es"])
    for word in ["you", "yes", "she", "we", "are", "cat"] {
      let results = prediction.suggestions(before: word, preferences: preferences, store: nil)
      XCTAssertFalse(results.contains { $0.kind == .word && $0.autoApply }, word)
    }
  }

  func testPrimaryLanguageDoesNotCorrectValidSecondaryWords() {
    let prediction = KeyboardPrediction()
    let preferences = KeyboardPreferences(values: ["language": "en", "secondaryLanguage": "es"])
    for word in ["hola", "gato", "eres", "gracias"] {
      let results = prediction.suggestions(before: word, preferences: preferences, store: nil)
      XCTAssertFalse(results.contains { $0.kind == .word && $0.autoApply }, word)
    }
  }

  func testPersonalWordIsProtectedAcrossSelectedLanguages() throws {
    try store.setWord("gell", language: "en", included: true)
    let results = KeyboardPrediction().suggestions(before: "gell",
      preferences: .init(values: ["language": "en", "secondaryLanguage": "es"]), store: store)
    XCTAssertFalse(results.contains { $0.kind == .word && $0.autoApply })
  }

  @MainActor func testToolsPanelTabDoesNotEditDocument() {
    let (surface, text) = editor("hello")
    surface.toggleTools()
    surface.key("tab")
    XCTAssertEqual(text(), "hello")
    surface.releaseMemory()
  }

  @MainActor func testToolsPanelHidesAndRejectsDocumentSuggestions() async throws {
    let (surface, text) = editor("teh")
    let suggestion = try await suggestionButton("the", surface: surface)
    surface.toggleTools()
    XCTAssertTrue(suggestion.isHidden)
    suggestion.sendActions(for: .touchUpInside)
    XCTAssertEqual(text(), "teh")
    surface.releaseMemory()
  }
}

extension KeyboardTests {
  @MainActor func testSearchReplacesSuggestionsAndLeavesDocumentUntouched() {
    let (surface, text) = editor("A message")
    surface.frame = CGRect(x: 0, y: 0, width: 402, height: 500)
    surface.hasFullAccess = false
    surface.setDocumentReturnTitle("send")
    surface.toggleTools()
    surface.layoutIfNeeded()
    let panel = surface.subviews.compactMap { $0 as? KeyboardToolsPanel }.first!
    XCTAssertEqual(surface.requiredHeight, surface.boardHeight + 186)
    XCTAssertEqual(panel.frame.minY, 0)
    XCTAssertEqual(surface.board.frame.minY, panel.requiredHeight)
    surface.key("c"); surface.key("a"); surface.key("t")
    surface.board.onCursor?(-1)
    surface.key("delete")
    surface.updateDeleteDrag(4)
    XCTAssertEqual(panel.query, "ct")
    XCTAssertEqual(text(), "A message")
    XCTAssertEqual(surface.board.returnTitle, "search")
    surface.setDocumentReturnTitle("done")
    XCTAssertEqual(surface.board.returnTitle, "search")
    surface.toggleTools()
    XCTAssertEqual(surface.board.returnTitle, "done")
    XCTAssertEqual(surface.requiredHeight, surface.boardHeight + 56)
    surface.releaseMemory()
  }

  @MainActor func testCompactSearchKeepsClackTileAndFieldSizes() {
    let panel = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: false, compact: true)
    panel.frame = CGRect(x: 0, y: 0, width: 320, height: panel.requiredHeight)
    panel.layoutIfNeeded()
    XCTAssertEqual(panel.requiredHeight, 151)
    XCTAssertEqual(panel.collection.bounds.height, 85)
    XCTAssertEqual(panel.searchField.bounds.height, 42)
    XCTAssertEqual(panel.searchField.frame.maxY, 143)
  }

  @MainActor func testStyleBoardStaysInsideKeyboardAndSelectsStyle() {
    let (surface, text) = editor("hello")
    let height = surface.requiredHeight
    surface.key("styles")
    XCTAssertEqual(surface.board.page, 3)
    XCTAssertEqual(surface.requiredHeight, height)
    XCTAssertFalse(surface.subviews.contains { $0 is KeyboardToolsPanel })
    surface.key("style:bold")
    XCTAssertEqual(surface.board.textStyle, .bold)
    XCTAssertEqual(surface.board.page, 0)
    XCTAssertEqual(text(), "hello")
    XCTAssertEqual(surface.board.holdAlternatives(for: "styles"), TextStyle.shortcutCases.map { "style:" + $0.rawValue })
    surface.releaseMemory()
  }

  @MainActor func testSearchIgnoresSupersededResponsesAndKeepsLocalResultsWhenOffline() async throws {
    let panel = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: true) { query in
      if query == "old" { try? await Task.sleep(for: .milliseconds(350)) }
      if query == "offline" { throw URLError(.notConnectedToInternet) }
      return [.init(title: query, url: URL(string: "https://example.com/\(query).gif")!, thumbnail: nil)]
    }
    panel.searchField.text = "old"; panel.searchNow()
    panel.searchField.text = "cat"; panel.searchNow()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(panel.items.contains { $0.title == "cat" })
    XCTAssertFalse(panel.items.contains { $0.title == "old" })
    XCTAssertTrue(panel.items.contains { $0.text == "🐱" || $0.text == "😺" })
    let remoteIndex = try XCTUnwrap(panel.items.firstIndex { $0.title == "cat" })
    XCTAssertTrue(panel.items[..<remoteIndex].allSatisfy { !$0.id.hasPrefix("remote:") })
    panel.searchField.text = "offline"; panel.searchNow()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(panel.items.contains { $0.title.contains("GIF search unavailable") })
  }

  @MainActor func testSearchWithoutFullAccessNeverContactsProviders() async throws {
    var called = false
    let panel = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: false) { _ in
      called = true; return []
    }
    panel.searchField.text = "cat"; panel.searchNow()
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertFalse(called)
    XCTAssertTrue(panel.items.contains { $0.text != nil })
    XCTAssertTrue(panel.items.contains { $0.title.contains("Full Access") })
  }

  @MainActor func testMediaSearchCopyAndSaveKeywords() async throws {
    let panel = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: true) { _ in [] }
    let index = try XCTUnwrap(panel.items.firstIndex { $0.id == "wat" })
    panel.collectionView(panel.collection, didSelectItemAt: IndexPath(item: index, section: 0))
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(UIPasteboard.general.hasImages)
    panel.beginTagging()
    panel.searchField.text = "confused, what"
    panel.submit()
    let saved = try XCTUnwrap(store.shortcuts(matching: "confused").first)
    XCTAssertEqual(saved.keywords, ["confused", "what"])
    XCTAssertFalse(store.mediaIsMissing(saved))
  }
}

extension KeyboardTests {
  @MainActor func testTryoutPastesAnimatedAttachmentWithoutLosingMessageOrGIFData() throws {
    let editor = KeyboardTryoutTextView()
    XCTAssertNotNil(editor.textLayoutManager)
    editor.text = "before after"
    editor.selectedRange = NSRange(location: 7, length: 5)
    let data = try Data(contentsOf: XCTUnwrap(KeyboardResources.url("dramatic_chipmunk", extension: "gif")))
    editor.insertMedia(data)
    XCTAssertTrue(editor.text.hasPrefix("before "))
    XCTAssertFalse(editor.text.contains("after"))
    let attachment = try XCTUnwrap(editor.attributedText.attribute(.attachment, at: 7, effectiveRange: nil) as? NSTextAttachment)
    XCTAssertEqual(attachment.contents, data)
    XCTAssertTrue(attachment.usesTextAttachmentView)
    XCTAssertEqual(attachment.bounds.size, CGSize(width: 80, height: 80))
    XCTAssertEqual(editor.selectedRange.location, editor.text.utf16.count)
  }

  @MainActor func testCopiedMediaSurvivesClosingSearchAndCanBeSavedOnce() async throws {
    let clipboard = KeyboardSearchClipboard()
    var panel: KeyboardToolsPanel? = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: true, clipboard: clipboard) { _ in [] }
    let index = try XCTUnwrap(panel?.items.firstIndex { $0.id == "wat" })
    panel!.collectionView(panel!.collection, didSelectItemAt: IndexPath(item: index, section: 0))
    try await Task.sleep(for: .milliseconds(200))
    weak var released = panel
    panel = nil
    XCTAssertNil(released)
    XCTAssertNotNil(clipboard.file)
    let reopened = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: true, clipboard: clipboard) { _ in [] }
    reopened.beginTagging()
    reopened.searchField.text = "wat"
    reopened.submit()
    reopened.beginTagging()
    reopened.searchField.text = "wat, confused"
    reopened.submit()
    XCTAssertEqual(try store.shortcuts().count, 1)
    XCTAssertEqual(try store.shortcuts().first?.keywords, ["confused", "wat"])
  }
}


extension KeyboardTests {
  @MainActor func testDoubleSpaceOpensSearchAtEmptyAndNumericFieldsAndRoutesTyping() {
    for initial in ["", "123", "hello", "🙂"] {
      let (surface, text) = editor(initial)
      surface.board.keyboardType = .numberPad
      var clock: TimeInterval = 10
      surface.now = { clock }
      surface.key(" "); clock += 0.1; surface.key(" ")
      let panel = surface.subviews.compactMap { $0 as? KeyboardToolsPanel }.first
      XCTAssertNotNil(panel)
      surface.key("c"); surface.key("a"); surface.key("t")
      XCTAssertEqual(panel?.query, "cat")
      XCTAssertEqual(text(), initial)
      surface.releaseMemory()
    }
  }
  @MainActor func testWriterReceivesLiteralDoubleSpaceAndNoKeyboardSearch() {
    let (surface, text) = editor("hello")
    surface.hostHandlesDoubleSpace = { true }
    surface.key(" "); surface.key(" ")
    XCTAssertEqual(text(), "hello  ")
    XCTAssertFalse(surface.subviews.contains { $0 is KeyboardToolsPanel })
    surface.releaseMemory()
  }
  @MainActor func testSlowOrInterruptedSpacesDoNotOpenSearch() {
    let (surface, text) = editor("123")
    var clock: TimeInterval = 10
    surface.now = { clock }
    surface.key(" "); clock += 0.5; surface.key(" ")
    XCTAssertEqual(text(), "123  ")
    surface.key("delete"); surface.key(" ")
    XCTAssertFalse(surface.subviews.contains { $0 is KeyboardToolsPanel })
    surface.releaseMemory()
  }
  @MainActor func testLocalSearchUpdatesBeforeDebounceAndGIFsStayLast() async throws {
    try store.save(.init(keywords: ["cat"], text: "my local cat"))
    var calls = 0
    let panel = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: true) { query in
      calls += 1
      return [.init(title: "Remote cat", url: URL(string: "https://example.com/cat.gif")!, thumbnail: nil)]
    }
    panel.appendSearch("cat")
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(panel.items.first?.text, "my local cat")
    XCTAssertTrue(panel.items.contains { $0.text == "🐱" || $0.text == "😺" })
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(panel.items.last?.title, "Remote cat")
    panel.cancelWork()
  }
  @MainActor func testClosingSearchCancelsRequestAndReleasesPanel() async throws {
    weak var released: KeyboardToolsPanel?
    var panel: KeyboardToolsPanel? = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: true) { _ in
      try await Task.sleep(for: .seconds(5)); return []
    }
    released = panel
    panel?.appendSearch("cat")
    panel?.searchNow()
    panel?.cancelWork(); panel = nil
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(released)
  }
  func testWriterForegroundLeaseExpiresAndClears() {
    let time = Date(timeIntervalSinceReferenceDate: 100)
    KeyboardHostContext.publishWriter(active: true, container: directory, now: time)
    XCTAssertTrue(KeyboardHostContext.writerIsActive(container: directory, now: time.addingTimeInterval(2)))
    XCTAssertFalse(KeyboardHostContext.writerIsActive(container: directory, now: time.addingTimeInterval(7)))
    KeyboardHostContext.publishWriter(active: false, container: directory)
    XCTAssertFalse(KeyboardHostContext.writerIsActive(container: directory, now: time))
  }
  func testShortcutSearchFiltersBeforeLimitAndBoundsHydration() throws {
    for i in 0..<50 { try store.save(.init(keywords: ["other"], text: "Other \(i)")) }
    try store.save(.init(keywords: ["cat"], text: "Needle"))
    let results = try store.searchShortcuts("cat", limit: 1)
    XCTAssertEqual(results.map(\.text), ["Needle"])
    XCTAssertEqual(results.first?.keywords, ["cat"])
    XCTAssertLessThanOrEqual(try store.searchShortcuts("").count, 40)
  }
}

extension KeyboardTests {
  @MainActor func testDoubleSpaceSearchAlsoWorksInDashMode() {
    let (surface, text) = editor("word")
    surface.key("Dashes"); surface.key(" "); surface.key(" ")
    XCTAssertEqual(text(), "word")
    XCTAssertTrue(surface.subviews.contains { $0 is KeyboardToolsPanel })
    surface.releaseMemory()
  }
  func testExtensionSQLiteCacheIsBounded() throws {
    let lowMemoryStore = KeyboardStore(saves: saves, containerURL: directory, lowMemory: true)
    let size = try saves.keyboardRead { try $0.scalarInt("PRAGMA cache_size") }
    XCTAssertEqual(size, -256)
    lowMemoryStore.trimMemory()
    XCTAssertNoThrow(try lowMemoryStore.preferences())
  }
  @MainActor func testLocalSearchLatencyWithLargeShortcutLibrary() throws {
    for i in 0..<250 { try store.save(.init(keywords: ["cat"], text: "Cat \(i)")) }
    let panel = KeyboardToolsPanel(catalog: KeyboardCatalog(), store: store, fullAccess: false)
    measure(metrics: [XCTClockMetric()]) {
      for _ in 0..<10 { panel.searchField.text = "cat"; panel.searchNow() }
    }
    XCTAssertEqual(panel.items.filter { $0.shortcut != nil }.count, 40)
    panel.cancelWork()
  }
}
