import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

class KeyboardTryoutController: UIViewController, UITextViewDelegate {
  let editor = KeyboardTryoutTextView()
  let surface = KeyboardSurface()
  var editorTop: NSLayoutConstraint!
  private let input = UIInputView(frame: .zero, inputViewStyle: .keyboard)
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Try It Out"
    view.backgroundColor = .black
    editor.font = .preferredFont(forTextStyle: .title2)
    editor.backgroundColor = .black
    editor.textColor = .white
    editor.delegate = self
    editor.accessibilityIdentifier = "keyboard.tryout"
    editor.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
    view.addSubview(editor)
    view.addSubview(surface)
    editor.translatesAutoresizingMaskIntoConstraints = false
    editorTop = editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
    NSLayoutConstraint.activate([
      editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      editorTop,
      editor.bottomAnchor.constraint(equalTo: surface.topAnchor),
    ])
    surface.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      surface.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -75),
    ])
    surface.boardHeight = 220
    let height = surface.heightAnchor.constraint(equalToConstant: surface.requiredHeight)
    height.isActive = true
    surface.heightChanged = { [weak height] value in height?.constant = value }
    surface.before = { [weak self] in
      guard let self else { return "" }
      return (self.editor.text as NSString).substring(to: self.editor.selectedRange.location)
    }
    surface.after = { [weak self] in
      guard let self else { return "" }
      return (self.editor.text as NSString).substring(from: NSMaxRange(self.editor.selectedRange))
    }
    surface.hasSelection = { [weak self] in (self?.editor.selectedRange.length ?? 0) > 0 }
    surface.insert = { [weak self] in self?.editor.insertText($0) }
    surface.delete = { [weak self] in self?.editor.deleteBackward() }
    surface.moveCursor = { [weak self] offset in
      guard let self, let selected = self.editor.selectedTextRange,
        let position = self.editor.position(from: selected.start, offset: offset)
      else { return }
      self.editor.selectedTextRange = self.editor.textRange(from: position, to: position)
    }
    surface.store = KeyboardStore()
    surface.onReturnToDocument = { [weak self] in self?.editor.becomeFirstResponder() }
    surface.hasFullAccess = true
    surface.board.needsGlobe = false
    surface.layer.cornerRadius = 28
    surface.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    surface.backgroundColor = UIColor(white: 0.13, alpha: 1)
    surface.board.dark = true
    surface.reloadSettings()
    #if DEBUG
    if !ProcessInfo.processInfo.arguments.contains("--keyboard-system-reference") { editor.inputView = input }
    if ProcessInfo.processInfo.arguments.contains("--keyboard-light") {
      view.overrideUserInterfaceStyle = .light
      view.backgroundColor = .white
      editor.backgroundColor = .white
      editor.textColor = .black
      surface.board.dark = false
      surface.backgroundColor = UIColor(red: 209/255, green: 212/255, blue: 218/255, alpha: 1)
    }
    if ProcessInfo.processInfo.arguments.contains("--keyboard-system-reference") {
      surface.isHidden = true
    }
    #else
    editor.inputView = input
    #endif
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Paste", primaryAction: UIAction { [weak self] _ in
      self?.editor.paste(nil)
    })
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    editor.becomeFirstResponder()
  }
  func textViewDidChange(_ textView: UITextView) { surface.refresh() }
  func textViewDidChangeSelection(_ textView: UITextView) { surface.refresh() }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    surface.releaseMemory()
  }
  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    surface.releaseMemory()
  }
}

/// The lessons use the production keyboard against a disposable text view.
final class KeyboardTutorialController: KeyboardTryoutController {
  private let scene = KeyboardQuestScene()
  private let instruction = UILabel()
  private let demo = UIButton(type: .system)
  private let nextLesson = UIButton(type: .system)
  private let pointer = UIView()
  private var step = 0
  private var demonstration: Timer?
  private var tick = 0
  private var completed = false
  private let lessons: [(String, String, String)] = [
    ("dragonloser", "dragon", "Drag left from Delete to remove ‘loser’. Drag right before lifting to restore letters."),
    ("", "1", "Hold Q for a number, then release. On iPad you can also flick Q down."),
    ("", "fire", "Slide through F, I, R, E without lifting to cast a fire spell."),
    ("shield", "shield", "Hold Space, then drag left to move the cursor before ‘shield’."),
  ]
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Keyboard Quest"
    editorTop.constant = 192
    scene.translatesAutoresizingMaskIntoConstraints = false
    instruction.translatesAutoresizingMaskIntoConstraints = false
    let controls = UIStackView(arrangedSubviews: [demo, nextLesson])
    controls.axis = .horizontal
    controls.distribution = .fillEqually
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scene); view.addSubview(instruction); view.addSubview(controls)
    instruction.font = .preferredFont(forTextStyle: .subheadline)
    instruction.adjustsFontForContentSizeCategory = true
    instruction.numberOfLines = 0
    instruction.textColor = .white
    NSLayoutConstraint.activate([
      scene.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scene.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      scene.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      scene.heightAnchor.constraint(equalToConstant: 65),
      instruction.topAnchor.constraint(equalTo: scene.bottomAnchor, constant: 4),
      instruction.leadingAnchor.constraint(equalTo: scene.leadingAnchor),
      instruction.trailingAnchor.constraint(equalTo: scene.trailingAnchor),
      instruction.heightAnchor.constraint(equalToConstant: 76),
      controls.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 2),
      controls.leadingAnchor.constraint(equalTo: scene.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: scene.trailingAnchor),
      controls.heightAnchor.constraint(equalToConstant: 40),
    ])
    demo.setTitle("Show Me", for: .normal)
    demo.addAction(UIAction { [weak self] _ in self?.showDemo() }, for: .touchUpInside)
    nextLesson.addAction(UIAction { [weak self] _ in self?.advance() }, for: .touchUpInside)
    demo.accessibilityIdentifier = "keyboard.tutorial.demo"
    nextLesson.accessibilityIdentifier = "keyboard.tutorial.nextLesson"
    pointer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.8)
    pointer.layer.cornerRadius = 12
    pointer.isUserInteractionEnabled = false
    pointer.isHidden = true
    view.addSubview(pointer)
    surface.onEdit = { [weak self] in self?.checkLesson() }
    resetLesson()
  }
  private func resetLesson() {
    stopDemo()
    surface.finishDeleteDrag()
    surface.clearCorrection()
    surface.preferences.values["autoCapitalize"] = "false"
    surface.preferences.values["autocorrect"] = "false"
    surface.board.uppercase = false
    surface.board.capsLock = false
    surface.board.textStyle = .regular
    surface.board.page = 0
    editor.text = lessons[step].0
    editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
    completed = false
    instruction.text = "\(step + 1)/4 · " + lessons[step].2
    scene.progress = step
    nextLesson.setTitle("Next", for: .normal)
    nextLesson.isEnabled = false
    surface.refresh()
  }
  private func checkLesson() {
    guard isViewLoaded else { return }
    let success = step == 3
      ? editor.text == "shield" && editor.selectedRange.location == 0
      : editor.text == lessons[step].1
    nextLesson.isEnabled = success
    guard success, !completed else { return }
    completed = true
    scene.progress = step + 1
    instruction.text = step == 3 ? "Quest complete! You restored the dragon’s name, unlocked numbers, cast a spell, and raised a shield." : "Well done! " + lessons[step].2
    nextLesson.setTitle(step == 3 ? "Play Again" : "Next", for: .normal)
    UIAccessibility.post(notification: .announcement, argument: step == 3 ? "Quest complete" : "Lesson complete")
  }
  override func textViewDidChangeSelection(_ textView: UITextView) {
    super.textViewDidChangeSelection(textView)
    if isViewLoaded, editorTop != nil { checkLesson() }
  }
  private func advance() {
    guard nextLesson.isEnabled else { return }
    step = (step + 1) % lessons.count
    resetLesson()
  }
  private func point(on key: String, offset: CGFloat = 0) {
    guard let rect = surface.board.frameForKey(key) else { return }
    let point = surface.board.convert(CGPoint(x: rect.midX + offset, y: rect.midY), to: view)
    pointer.frame = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
    pointer.isHidden = UIAccessibility.isReduceMotionEnabled
    surface.board.demonstrationKey = key
  }
  private func showDemo() {
    resetLesson()
    tick = 0
    demo.isEnabled = false
    surface.isUserInteractionEnabled = false
    demonstration = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.demonstrateTick()
    }
  }
  private func demonstrateTick() {
    tick += 1
    switch step {
    case 0:
      point(on: "delete", offset: -CGFloat(min(tick, 5)) * 14)
      surface.updateDeleteDrag(min(tick, 5))
      if tick == 7 { surface.finishDeleteDrag(); stopDemo() }
    case 1:
      point(on: "q")
      if tick == 4 { surface.key("1"); stopDemo() }
    case 2:
      let letters = Array("fire")
      point(on: String(letters[min(tick - 1, 3)]))
      if tick == 5 {
        var centers: [Character: CGPoint] = [:]
        for c in "qwertyuiopasdfghjklzxcvbnm" {
          if let rect = surface.board.frameForKey(String(c)) { centers[c] = CGPoint(x: rect.midX, y: rect.midY) }
        }
        let samples = letters.compactMap { c in centers[c].map { SwipeSample(point: $0, letter: c) } }
        surface.board.onSwipe?(samples, centers)
        checkLesson(); stopDemo()
      }
    default:
      point(on: " ", offset: -CGFloat(tick) * 9)
      if tick > 2 { surface.board.onCursor?(-1) }
      if tick == 8 { checkLesson(); stopDemo() }
    }
  }
  private func stopDemo() {
    demonstration?.invalidate(); demonstration = nil
    pointer.isHidden = true
    surface.board.demonstrationKey = nil
    surface.isUserInteractionEnabled = true
    demo.isEnabled = true
  }
  override func viewWillDisappear(_ animated: Bool) {
    stopDemo()
    super.viewWillDisappear(animated)
  }
  deinit { demonstration?.invalidate() }
}

/// Small pixel sprites drawn as rectangles; no textures or animation frames retained.
private final class KeyboardQuestScene: UIView {
  var progress = 0 { didSet { setNeedsDisplay(); accessibilityValue = "\(progress) of 4 lessons complete" } }
  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    isAccessibilityElement = true
    accessibilityLabel = "Knight and dragon"
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  override func draw(_ rect: CGRect) {
    let knight = ["00111100", "01111110", "01100110", "00111100", "11111111", "10111101", "00100100", "01100110"]
    let dragon = ["11000011", "01111110", "11011011", "11111111", "00111110", "11111000", "01001000", "11001100"]
    func sprite(_ rows: [String], x: CGFloat, color: UIColor) {
      color.setFill()
      for (y, row) in rows.enumerated() {
        for (column, bit) in row.enumerated() where bit == "1" {
          UIRectFill(CGRect(x: x + CGFloat(column) * 6, y: 8 + CGFloat(y) * 6, width: 6, height: 6))
        }
      }
    }
    sprite(knight, x: 12 + CGFloat(progress) * 12, color: .systemIndigo)
    sprite(dragon, x: bounds.width - 72, color: progress == 4 ? .systemGreen : .systemOrange)
    UIColor.systemYellow.setFill()
    for i in 0..<progress { UIRectFill(CGRect(x: bounds.midX - 30 + CGFloat(i) * 18, y: 28, width: 10, height: 10)) }
  }
}
