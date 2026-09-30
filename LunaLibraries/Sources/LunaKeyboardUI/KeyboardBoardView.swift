import LunaKeyboardCore
import UIKit

// Metrics and popup outlines retained from the original system-matching board.
public struct BoardSpacing {
  let keyCornerRadius: CGFloat = 6
  let betweenKeys: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 6
}
extension CGPoint {
  func offset(x: CGFloat = 0, y: CGFloat = 0) -> CGPoint { CGPoint(x: self.x + x, y: self.y + y) }
}

public final class KeyboardBoardView: UIView {
  public var onKey: ((String) -> Void)?
  public var onSwipe: (([SwipeSample], [Character: CGPoint]) -> Void)?
  public var onDeleteDrag: ((Int) -> Void)?
  public var onDeleteDragEnd: (() -> Void)?
  public var onDismiss: (() -> Void)?
  public var onNextKeyboard: (() -> Void)?
  public var isPad = UIDevice.current.userInterfaceIdiom == .pad { didSet { rebuild() } }
  public var onCursor: ((Int) -> Void)?
  public var onGlobe: ((UIView, UIEvent) -> Void)?
  public var language = "en" { didSet { if oldValue != language { rebuild() } } }
  public var uppercase = false { didSet { updateAccessibility(); setNeedsDisplay() } }
  public var capsLock = false { didSet { updateAccessibility(); setNeedsDisplay() } }
  public var blank = false { didSet { setNeedsDisplay() } }
  public var preview = true
  public var swipeEnabled = true
  public var textStyle: TextStyle = .regular { didSet { updateAccessibility(); setNeedsDisplay() } }
  public var needsGlobe = true { didSet { if oldValue != needsGlobe { rebuild() } } }
  public var keyboardType: UIKeyboardType = .default { didSet { if oldValue != keyboardType { rebuild() } } }
  public var returnTitle = "return" { didSet { setNeedsDisplay() } }
  public var theme: KeyboardTheme = .system { didSet { setNeedsDisplay() } }
  public var demonstrationKey: String? { didSet { setNeedsDisplay() } }
  public func frameForKey(_ key: String) -> CGRect? { keys.first { $0.value == key }?.frame }
  public var dark = false { didSet { setNeedsDisplay() } }
  public var page = 0 { didSet { rebuild() } }
  private struct Key {
    var value: String
    var frame: CGRect
    var special: Bool
  }
  private var keys: [Key] = []
  private var active: Int?
  private var startPoint = CGPoint.zero
  private var cursorPoint = CGPoint.zero
  private var trace: [SwipeSample] = []
  private var swiping = false
  private var cursorDragging = false
  private var deleteDragging = false
  private var flick: String?
  private var alternatives: [String] = []
  private var alternativeIndex = 0
  private var longPress: Timer?
  private var repeating: Timer?
  private let popup = KeyboardPopupView()
  public override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    isMultipleTouchEnabled = false
    accessibilityIdentifier = "keyboard.board"
    clipsToBounds = false
  }
  public required init?(coder: NSCoder) { fatalError("init(coder:)") }
  deinit {
    longPress?.invalidate()
    repeating?.invalidate()
  }
  public override func layoutSubviews() {
    super.layoutSubviews()
    rebuild()
  }
  public override func didMoveToSuperview() {
    super.didMoveToSuperview()
    if let superview { superview.addSubview(popup) } else { popup.removeFromSuperview() }
  }
  private var gap: CGFloat { isPad ? 8 : 6 }
  private func rebuild() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let portrait = bounds.width < 600
    let rowGap: CGFloat =
      isPad ? (portrait ? 8 : 11) : (portrait ? 10 : 8)
    let h = (bounds.height - 6 - rowGap * 3) / 4
    let w = (bounds.width - 7 - gap * 9) / 10
    var all: [Key] = []
    func row(
      _ values: [String], index: Int, inset: CGFloat = 3, width: CGFloat? = nil,
      special: Bool = false
    ) {
      let width = width ?? w
      for (i, v) in values.enumerated() {
        all.append(
          .init(
            value: v,
            frame: CGRect(
              x: inset + CGFloat(i) * (width + gap), y: 2 + CGFloat(index) * (h + rowGap),
              width: width, height: h), special: special))
      }
    }
    let top = page == 0 ? "qwertyuiop" : page == 1 ? "1234567890" : "[]{}#%^*+="
    let mid =
      page == 0
      ? (language.hasPrefix("es") ? "asdfghjklñ" : "asdfghjkl")
      : page == 1 ? "-/:;()$&@\"" : "_\\|~<>€£¥•"
    row(top.map(String.init), index: 0)
    row(
      mid.map(String.init), index: 1,
      inset: (bounds.width - (CGFloat(mid.count) * (w + gap) - gap)) / 2)
    let bottom = page == 0 ? "zxcvbnm" : ".,?!'"
    let side = w * 1.35
    let centerStart = side + gap + 3
    let centerWidth =
      page == 0
      ? w
      : (bounds.width - 2 * centerStart - gap * CGFloat(bottom.count - 1)) / CGFloat(bottom.count)
    row(
      bottom.map(String.init), index: 2,
      inset: (bounds.width - (CGFloat(bottom.count) * (centerWidth + gap) - gap)) / 2,
      width: centerWidth)
    all.append(
      .init(
        value: page == 0 ? "shift" : page == 1 ? "#+=" : "123",
        frame: CGRect(x: 3, y: 2 + 2 * (h + rowGap), width: side, height: h), special: true))
    all.append(
      .init(
        value: "delete",
        frame: CGRect(x: bounds.width - side - 4, y: 2 + 2 * (h + rowGap), width: side, height: h),
        special: true))
    var controls = [page == 0 ? "123" : "ABC", "styles"]
    if needsGlobe { controls.append("globe") }
    var suffix: [String] = []
    if keyboardType == .emailAddress {
      suffix = ["@", "."]
    } else if keyboardType == .URL {
      suffix = ["/", "."]
    } else if keyboardType == .webSearch {
      suffix = ["."]
    } else if keyboardType == .twitter {
      suffix = ["@", "#"]
    }
    var x: CGFloat = 3
    let y = 2 + 3 * (h + rowGap)
    for v in controls {
      all.append(.init(value: v, frame: CGRect(x: x, y: y, width: w, height: h), special: true))
      x += w + gap
    }
    let retWidth = w * 2.1
    let spaceWidth = max(
      w, bounds.width - 4 - x - retWidth - gap - CGFloat(suffix.count) * (w + gap))
    all.append(
      .init(value: " ", frame: CGRect(x: x, y: y, width: spaceWidth, height: h), special: false))
    x += spaceWidth + gap
    for v in suffix {
      all.append(.init(value: v, frame: CGRect(x: x, y: y, width: w, height: h), special: false))
      x += w + gap
    }
    all.append(
      .init(
        value: "return", frame: CGRect(x: x, y: y, width: max(w, bounds.width - x - 4), height: h),
        special: true))
    // Full-width iPad boards have punctuation and Tab available on letters.
    if isPad && page == 0 {
      let firstRow: [String] = ["tab"] + top.map(String.init) + ["delete"]
      let secondRow: [String] = mid.map(String.init) + ["return"]
      let thirdRow: [String] = ["shift"] + bottom.map(String.init) + [",", ".", "shift"]
      var lastRow = ["123", "styles"]
      if needsGlobe { lastRow.append("globe") }
      lastRow += [" ", "dismiss"]
      let rows = [firstRow, secondRow, thirdRow, lastRow]
      all = []
      for (r, values) in rows.enumerated() {
        let units = CGFloat(values.count + (r == 3 ? 5 : 0))
        let unit = (bounds.width - 6 - gap * CGFloat(values.count - 1)) / units
        var x: CGFloat = 3
        for v in values {
          let width = v == " " ? unit * 6 : unit
          all.append(.init(value: v, frame: CGRect(x: x, y: 2 + CGFloat(r) * (h + rowGap), width: width, height: h), special: v.count > 1))
          x += width + gap
        }
      }
    }
    keys = all
    accessibilityElements = all.map { key in
      let element = KeyboardKeyAccessibility(accessibilityContainer: self)
      element.accessibilityLabel = accessibilityName(key.value)
      element.accessibilityHint = textStyle == .regular ? nil : "Inserts \(textStyle.rawValue) text"
      element.accessibilityTraits = .keyboardKey
      element.accessibilityFrameInContainerSpace = key.frame
      element.action = { [weak self] in
        guard let self else { return }
        self.cancelRepeatingDelete()
        if key.value == "globe" { self.onNextKeyboard?() }
        else if key.value == "dismiss" { self.onDismiss?() }
        else { self.onKey?(key.value) }
      }
      return element
    }
    setNeedsDisplay()
  }
  private func updateAccessibility() {
    guard let elements = accessibilityElements as? [UIAccessibilityElement], elements.count == keys.count else { return }
    for (element, key) in zip(elements, keys) {
      element.accessibilityLabel = accessibilityName(key.value)
      element.accessibilityHint = textStyle == .regular ? nil : "Inserts \(textStyle.rawValue) text"
    }
  }
  private func accessibilityName(_ value: String) -> String {
    switch value {
    case "shift": return capsLock ? "Caps lock" : "Shift"
    case "delete": return "Delete"
    case "globe": return "Next keyboard"
    case "styles": return "Text styles"
    case "dismiss": return "Hide keyboard"
    case "tab": return "Tab"
    default: return label(value).styleErased
    }
  }
  public func firstAlternative(for value: String) -> String? {
    if page == 0, let i = Array("qwertyuiop").firstIndex(of: value.first ?? " "), value.count == 1 {
      return String(Array("1234567890")[i])
    }
    let padSymbols = Dictionary(uniqueKeysWithValues: zip(Array("asdfghjklzxcvbnm").map(String.init), Array(#"@#$&*()'"%_-+=/;"#).map(String.init)))
    if isPad, page == 0, let symbol = padSymbols[value] { return symbol }
    return Accents.accents(for: value).first ?? NumbersAndSymbols.altSymbols(for: value).first
  }
  private func label(_ value: String) -> String {
    switch value {
    case "shift": return capsLock ? "⇪" : "⇧"
    case "delete": return "⌫"
    case "globe": return "◎"
    case "styles": return "Aa"
    case "tab": return "⇥"
    case "dismiss": return "⌄"
    case "return": return returnTitle
    case " ": return language.hasPrefix("es") ? "espacio" : language == "it" ? "spazio" : "space"
    default: return uppercase ? value.uppercased() : value
    }
  }
  public override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    var normal: UIColor = dark ? UIColor(white: 0.36, alpha: 1) : .white
    var special: UIColor =
      dark ? UIColor(white: 0.22, alpha: 1) : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1)
    var foreground: UIColor = dark ? .white : .black
    switch theme {
    case .system: break
    case .moonlight:
      normal = UIColor(red: 0.25, green: 0.22, blue: 0.42, alpha: 1)
      special = UIColor(red: 0.40, green: 0.32, blue: 0.58, alpha: 1)
      foreground = .white
    case .ocean:
      normal = UIColor(red: 0.05, green: 0.30, blue: 0.40, alpha: 1)
      special = UIColor(red: 0.04, green: 0.20, blue: 0.29, alpha: 1)
      foreground = .white
    case .highContrast:
      normal = dark ? .black : .white; special = normal; foreground = dark ? .white : .black
    }
    for (i, key) in keys.enumerated() {
      ctx.saveGState()
      ctx.setShadow(
        offset: CGSize(width: 0, height: 1), blur: 0,
        color: UIColor.black.withAlphaComponent(0.3).cgColor)
      (i == active || key.value == demonstrationKey ? UIColor.systemBlue : key.special ? special : normal).setFill()
      let outline = UIBezierPath(roundedRect: key.frame, cornerRadius: 6)
      outline.fill()
      if theme == .highContrast { foreground.setStroke(); outline.lineWidth = 2; outline.stroke() }
      ctx.restoreGState()
      guard !cursorDragging && (!blank || key.special) else { continue }
      let text = label(key.value)
      let title = key.special || key.value == " " ? text : textStyle.style(text)
      let size: CGFloat = key.special || key.value == " " ? 16 : 22
      drawText(title, in: key.frame, color: foreground, size: size)
      if isPad, !key.special, let alt = firstAlternative(for: key.value), key.value != " " {
        drawText(alt, in: CGRect(x: key.frame.maxX - 20, y: key.frame.minY + 2, width: 16, height: 14), color: foreground.withAlphaComponent(0.8), size: 11)
      }
    }
    if swiping, trace.count > 1 {
      UIColor.systemBlue.withAlphaComponent(0.55).setStroke()
      let path = UIBezierPath()
      path.lineWidth = 4
      path.lineCapStyle = .round
      path.move(to: trace[0].point)
      for p in trace.dropFirst() { path.addLine(to: p.point) }
      path.stroke()
    }
  }
  private func nearest(_ point: CGPoint) -> Int? {
    guard bounds.insetBy(dx: -12, dy: -20).contains(point) else { return nil }
    return keys.indices.min { a, b in
      distance(point, keys[a].frame) < distance(point, keys[b].frame)
    }
  }
  private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
    hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
  }
  public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    reset()
    guard let touch = touches.first, let i = nearest(touch.location(in: self)) else { return }
    active = i
    startPoint = touch.location(in: self)
    cursorPoint = startPoint
    let key = keys[i]
    if key.value == "globe", let event {
      onGlobe?(self, event)
      return
    }

    if let c = key.value.first, key.value.count == 1, c.isLetter, page == 0 {
      trace = [.init(point: startPoint, letter: c)]
    }
    if preview && !key.special && key.value != " " {
      showPopup(index: i, options: [label(key.value)])
    }
    longPress = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
      self?.beginHold()
    }
    setNeedsDisplay()
  }
  private func beginHold() {
    guard let i = active else { return }
    let value = keys[i].value
    if value == "delete" {
      onKey?("delete")
      repeating = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: true) { [weak self] _ in
        self?.onKey?("delete")
      }
      return
    }
    if value == " " {
      cursorDragging = true
      popup.isHidden = true
      setNeedsDisplay()
      return
    }
    if value == "globe" { return }
    let title = label(value)
    alternatives = Accents.accents(for: title)
    if alternatives.isEmpty { alternatives = NumbersAndSymbols.altSymbols(for: value) }
    if value == ".", keyboardType == .URL || keyboardType == .emailAddress {
      alternatives = [".com", ".net", ".edu", ".org"]
    }
    if let index = Array("qwertyuiop").firstIndex(of: value.first ?? " "), page == 0 {
      alternatives.insert(String(Array("1234567890")[index]), at: 0)
    }
    guard !alternatives.isEmpty else { return }
    alternativeIndex = 0
    showPopup(index: i, options: alternatives)
  }
  public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first, let active else { return }
    let p = touch.location(in: self)
    if keys[active].value == "delete", p.x < startPoint.x - 18 || deleteDragging {
      deleteDragging = true
      cancelRepeatingDelete()
      onDeleteDrag?(max(0, Int((startPoint.x - p.x) / 14)))
      return
    }
    if isPad, !keys[active].special, p.y - startPoint.y > 20,
      abs(p.x - startPoint.x) < 30, let alternative = firstAlternative(for: keys[active].value) {
      flick = alternative
      swiping = false
      longPress?.invalidate()
      showPopup(index: active, options: [alternative])
      return
    }
    if flick != nil { return }
    if cursorDragging {
      let delta = Int((p.x - cursorPoint.x) / 9)
      if delta != 0 {
        onCursor?(delta)
        cursorPoint.x += CGFloat(delta) * 9
      }
      return
    }
    if !alternatives.isEmpty {
      alternativeIndex = popup.selection(at: convert(p, to: popup))
      popup.selected = alternativeIndex
      return
    }
    if swipeEnabled, page == 0, !trace.isEmpty, let i = nearest(p), let c = keys[i].value.first,
      c.isLetter, keys[i].value.count == 1
    {
      if hypot(p.x - startPoint.x, p.y - startPoint.y) > 18 {
        swiping = true
        longPress?.invalidate()
        popup.isHidden = true
      }
      if swiping && (trace.last.map { hypot($0.point.x - p.x, $0.point.y - p.y) > 3 } ?? true) {
        if trace.count >= 128 {
          trace = trace.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        }
        trace.append(.init(point: p, letter: c))
        setNeedsDisplay()
        return
      }
    }
    if !swiping, hypot(p.x - startPoint.x, p.y - startPoint.y) > 18 {
      longPress?.invalidate()
      if let i = nearest(p), i != active {
        self.active = i
        showPopup(index: i, options: [label(keys[i].value)])
      }
    }
  }
  public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    defer { reset() }
    guard let i = active, !cursorDragging else { return }
    if deleteDragging { onDeleteDragEnd?(); return }
    if let flick { onKey?(flick); return }
    if keys[i].value == "dismiss" { onDismiss?(); return }
    if keys[i].value == "delete" {
      if repeating == nil { onKey?("delete") }
      return
    }
    if !alternatives.isEmpty {
      onKey?(alternatives[min(alternativeIndex, alternatives.count - 1)])
      return
    }
    if swiping {
      var centers: [Character: CGPoint] = [:]
      for key in keys where key.value.count == 1 && key.value.first!.isLetter {
        centers[key.value.first!] = CGPoint(x: key.frame.midX, y: key.frame.midY)
      }
      onSwipe?(trace, centers)
      return
    }
    if keys[i].value != "delete" && keys[i].value != "globe" { onKey?(keys[i].value) }
  }
  public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }
  public func cancelRepeatingDelete() {
    longPress?.invalidate()
    longPress = nil
    repeating?.invalidate()
    repeating = nil
  }
  public func reset() {
    if deleteDragging { onDeleteDragEnd?() }
    deleteDragging = false
    flick = nil
    longPress?.invalidate()
    longPress = nil
    repeating?.invalidate()
    repeating = nil
    active = nil
    alternatives = []
    trace = []
    swiping = false
    cursorDragging = false
    popup.isHidden = true
    setNeedsDisplay()
  }
  private func showPopup(index: Int, options: [String]) {
    guard let parent = superview else { return }
    let frame = convert(keys[index].frame, to: parent)
    popup.configure(keyFrame: frame, options: options, parentWidth: parent.bounds.width, dark: dark)
    parent.bringSubviewToFront(popup)
  }
}
private final class KeyboardKeyAccessibility: UIAccessibilityElement {
  var action: (() -> Void)?
  override func accessibilityActivate() -> Bool {
    action?()
    return true
  }
}
private func drawText(_ text: String, in rect: CGRect, color: UIColor, size: CGFloat) {
  let attrs: [NSAttributedString.Key: Any] = [
    .font: UIFont.systemFont(ofSize: size), .foregroundColor: color,
  ]
  let measured = (text as NSString).size(withAttributes: attrs)
  (text as NSString).draw(
    at: CGPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2),
    withAttributes: attrs)
}
private final class KeyboardPopupView: UIView {
  private var options: [String] = []
  private var key = CGRect.zero
  private var shape: PopUpKeyBezierPath = .center
  private var dark = false
  var selected = 0 { didSet { setNeedsDisplay() } }
  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isOpaque = false
    clipsToBounds = false
    isHidden = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  func configure(keyFrame: CGRect, options: [String], parentWidth: CGFloat, dark: Bool) {
    self.options = options
    self.dark = dark
    selected = 0
    key = CGRect(origin: .zero, size: keyFrame.size)
    if options.count > 1 {
      let width = min(parentWidth - 8, CGFloat(options.count) * max(32, key.width))
      shape =
        keyFrame.midX > parentWidth / 2
        ? .expandLeft(menuWidth: width) : .expandRight(menuWidth: width)
    } else if keyFrame.minX < key.width * 0.25 {
      shape = .right
    } else if keyFrame.maxX > parentWidth - key.width * 0.25 {
      shape = .left
    } else {
      shape = .center
    }
    let menu = shape.menuFrame(keyBounds: key)
    let full = key.union(menu).insetBy(dx: -3, dy: -3)
    frame = full.offsetBy(dx: keyFrame.minX, dy: keyFrame.minY)
    // Draw in an expanded canvas so UIKit does not clip negative popup y.
    key.origin = CGPoint(x: -full.minX, y: -full.minY)
    isHidden = false
    setNeedsDisplay()
  }
  private var menuFrame: CGRect {
    shape.menuFrame(keyBounds: CGRect(origin: .zero, size: key.size)).offsetBy(
      dx: key.minX, dy: key.minY)
  }
  func selection(at point: CGPoint) -> Int {
    max(
      0,
      min(
        options.count - 1,
        Int((point.x - menuFrame.minX) / (menuFrame.width / CGFloat(max(1, options.count))))))
  }
  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    ctx.saveGState()
    ctx.translateBy(x: key.minX, y: key.minY)
    ctx.setShadow(
      offset: CGSize(width: 0, height: 2), blur: 3,
      color: UIColor.black.withAlphaComponent(0.3).cgColor)
    (dark ? UIColor(white: 0.45, alpha: 1) : .white).setFill()
    shape.path(keyBounds: CGRect(origin: .zero, size: key.size), spacing: BoardSpacing()).fill()
    ctx.restoreGState()
    for (i, text) in options.enumerated() {
      let r = CGRect(
        x: menuFrame.minX + CGFloat(i) * menuFrame.width / CGFloat(options.count),
        y: menuFrame.minY, width: menuFrame.width / CGFloat(options.count), height: menuFrame.height
      )
      if options.count > 1, i == selected {
        UIColor.systemBlue.setFill()
        UIBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), cornerRadius: 5).fill()
      }
      drawText(
        text, in: r, color: dark || (options.count > 1 && i == selected) ? .white : .black,
        size: options.count > 1 ? 22 : 30)
    }
  }
}
