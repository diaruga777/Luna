import LunaKeyboardCore
import UIKit

// Keep keycaps and callouts on the same radius and spacing grid.
public struct BoardSpacing {
  let keyCornerRadius: CGFloat = 8
  let betweenKeys: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 6
}
extension CGPoint {
  func offset(x: CGFloat = 0, y: CGFloat = 0) -> CGPoint { CGPoint(x: self.x + x, y: self.y + y) }
}

public final class KeyboardBoardView: UIView {
  public var onKey: ((String) -> Void)?
  public var onSearch: (() -> Void)?
  public var onSwipe: (([SwipeSample], [Character: CGPoint]) -> Void)?
  public var onDeleteDrag: ((Int) -> Void)?
  public var onDeleteDragEnd: (() -> Void)?
  public var onDismiss: (() -> Void)?
  public var onNextKeyboard: (() -> Void)?
  public var isPad = UIDevice.current.userInterfaceIdiom == .pad { didSet { rebuild() } }
  public var onCursor: ((Int) -> Void)?
  public var onGlobe: ((UIView, UIEvent) -> Void)?
  public var language = "en" { didSet { if oldValue != language { rebuild() } } }
  public var uppercase = false { didSet { if oldValue != uppercase { updateAccessibility(); setNeedsDisplay() } } }
  public var capsLock = false { didSet { if oldValue != capsLock { updateAccessibility(); setNeedsDisplay() } } }
  public var blank = false { didSet { if oldValue != blank { setNeedsDisplay() } } }
  public var dashesMode = false { didSet { if oldValue != dashesMode { updateAccessibility(); setNeedsDisplay() } } }
  public var preview = true
  public var swipeEnabled = true
  public var textStyle: TextStyle = .regular { didSet { if oldValue != textStyle { updateAccessibility(); setNeedsDisplay() } } }
  public var needsGlobe = true { didSet { if oldValue != needsGlobe { rebuild() } } }
  public var keyboardType: UIKeyboardType = .default { didSet { if oldValue != keyboardType { rebuild() } } }
  public var returnTitle = "return" { didSet { if oldValue != returnTitle { setNeedsDisplay() } } }
  public var theme: KeyboardTheme = .system { didSet { if oldValue != theme { rebuild() } } }
  public var demonstrationKey: String? { didSet { setNeedsDisplay() } }
  public func frameForKey(_ key: String) -> CGRect? { keys.first { $0.value == key }?.frame }
  public var dark = false { didSet {
    if oldValue != dark {
      stylesGlass.overrideUserInterfaceStyle = dark ? .dark : .light
      stylesLabel.textColor = dark ? .white : .black
      setNeedsDisplay()
    }
  } }
  public var page = 0 { didSet {
    guard oldValue != page else { return }
    reset()
    rebuild()
    if (oldValue == 3 || page == 3), !UIAccessibility.isReduceMotionEnabled {
      let transition = CATransition()
      transition.type = .fade; transition.duration = 0.16
      layer.add(transition, forKey: "stylePage")
    }
  } }
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
  private let stylesGlass = KeyboardAppearance.glass(interactive: true)
  private let stylesLabel = UILabel()
  public override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    isMultipleTouchEnabled = false
    accessibilityIdentifier = "keyboard.board"
    clipsToBounds = false
    stylesGlass.isUserInteractionEnabled = false
    stylesGlass.isAccessibilityElement = false
    if #available(iOS 26, *) { stylesGlass.cornerConfiguration = .capsule(maximumRadius: 8) }
    else { stylesGlass.layer.cornerRadius = 8 }
    stylesLabel.text = "Aa"
    stylesLabel.font = .systemFont(ofSize: 17, weight: .medium)
    stylesLabel.textAlignment = .center
    stylesGlass.contentView.addSubview(stylesLabel)
    addSubview(stylesGlass)
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
    let allowsStyles = keyboardType == .default || keyboardType == .twitter
    var controls = page == 3 ? ["123", "ABC"] : [page == 0 ? "123" : "ABC"] + (allowsStyles ? ["styles"] : [])
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
    let controlWidth = needsGlobe ? w : bounds.width * 0.11
    for v in controls {
      all.append(.init(value: v, frame: CGRect(x: x, y: y, width: controlWidth, height: h), special: true))
      x += controlWidth + gap
    }
    let retWidth = bounds.width * 0.22
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
    if page == 3 {
      all.removeAll { $0.frame.minY < y }
      let styleRows: [[TextStyle]] = [
        [.gothic, .ransom, .boxed, .inverseBoxed, .circled, .zalgo],
        [.boldItalic, .monospace, .spaced, .script, .superscript, .doubleStroke],
        [.regular, .bold, .italic, .underscore, .strikethrough],
      ]
      for (r, styles) in styleRows.enumerated() {
        let inset: CGFloat = r == 2 ? side + gap + 3 : 3
        let width = (bounds.width - inset - 4 - CGFloat(styles.count - 1) * gap) / CGFloat(styles.count)
        row(styles.map { "style:" + $0.rawValue }, index: r, inset: inset, width: width)
      }
      all.append(.init(value: "shift", frame: CGRect(x: 3, y: 2 + 2 * (h + rowGap), width: side, height: h), special: true))
    }
    // Snap shared edges to physical pixels to avoid soft, uneven keycaps.
    let scale = traitCollection.displayScale
    all = all.map { key in
      var key = key
      let rect = key.frame
      key.frame = CGRect(x: (rect.minX * scale).rounded() / scale,
                         y: (rect.minY * scale).rounded() / scale,
                         width: (rect.maxX * scale).rounded() / scale - (rect.minX * scale).rounded() / scale,
                         height: (rect.maxY * scale).rounded() / scale - (rect.minY * scale).rounded() / scale)
      return key
    }
    keys = all
    stylesGlass.isHidden = theme == .highContrast || !all.contains { $0.value == "styles" }
    if let styleKey = all.first(where: { $0.value == "styles" }) {
      stylesGlass.frame = styleKey.frame
      stylesLabel.frame = stylesGlass.bounds
    }
    accessibilityElements = all.map { key in
      let element = KeyboardKeyAccessibility(accessibilityContainer: self)
      element.accessibilityLabel = accessibilityName(key.value)
      element.accessibilityHint = textStyle == .regular ? nil : "Inserts \(textStyle.rawValue) text"
      element.accessibilityTraits = .keyboardKey
      if key.value == "-" || key.value == " " {
        element.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Toggle dashes mode") { [weak self] _ in
          guard let self else { return false }
          self.onKey?(self.dashesMode ? "Spaces" : "Dashes")
          return true
        }, UIAccessibilityCustomAction(name: "Search emoji, shortcuts and GIFs") { [weak self] _ in
          self?.onSearch?(); return true
        }]
      }
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
    if value.hasPrefix("style:") { return String(value.dropFirst(6)) + " style" }
    switch value {
    case "shift": return capsLock ? "Caps lock" : "Shift"
    case "delete": return "Delete"
    case "globe": return "Next keyboard"
    case "styles": return "Text styles"
    case "dismiss": return "Hide keyboard"
    case "tab": return "Tab"
    case " ": return dashesMode ? "Dash" : label(value)
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
    if value.hasPrefix("style:"), let style = TextStyle(rawValue: String(value.dropFirst(6))) {
      return style.style(uppercase ? "ABC" : "abc")
    }
    switch value {
    case "shift": return capsLock ? "⇪" : "⇧"
    case "delete": return "⌫"
    case "globe": return "◎"
    case "styles": return "Aa"
    case "tab": return "⇥"
    case "dismiss": return "⌄"
    case "return": return returnTitle
    case " ": return dashesMode ? "-" : language.hasPrefix("es") ? "espacio" : language == "it" ? "spazio" : "space"
    default: return uppercase ? value.uppercased() : value
    }
  }
  public override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    var normal = KeyboardAppearance.key(dark: dark)
    var special = KeyboardAppearance.modifier(dark: dark)
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
      let pressed = i == active || key.value == demonstrationKey
      let shifted = key.value == "shift" && uppercase
      let selectedStyle = key.value == "style:" + textStyle.rawValue
      let action = key.value == "return" && returnTitle != "return"
      var fill = key.special ? special : normal
      var ink = foreground
      if shifted { fill = .white; ink = .black }
      if action || selectedStyle { fill = .systemBlue; ink = .white }
      if pressed {
        fill = key.special ? normal : special
        if action { fill = .systemBlue.withAlphaComponent(0.7); ink = .white }
      }
      if key.value == "styles", theme != .highContrast {
        ctx.restoreGState()
        stylesLabel.alpha = cursorDragging ? 0 : 1
        continue
      }
      fill.setFill()
      let outline = UIBezierPath(roundedRect: key.frame, cornerRadius: BoardSpacing().keyCornerRadius)
      outline.fill()
      if theme == .highContrast { foreground.setStroke(); outline.lineWidth = 2; outline.stroke() }
      ctx.restoreGState()
      guard !cursorDragging && (!blank || key.special) else { continue }
      let text = label(key.value)
      let title = key.special || key.value == " " || key.value.hasPrefix("style:") ? text : textStyle.style(text)
      let size: CGFloat = key.special || key.value == " " ? 16 : key.value.hasPrefix("style:") ? 20 : 25
      if key.value == "shift" || key.value == "delete" || key.value == "globe" {
        let name = key.value == "shift" ? (capsLock ? "capslock.fill" : uppercase ? "shift.fill" : "shift") : key.value == "delete" ? (pressed ? "delete.left.fill" : "delete.left") : "globe"
        let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))?.withTintColor(ink, renderingMode: .alwaysOriginal)
        if let image {
          image.draw(at: CGPoint(x: key.frame.midX - image.size.width / 2, y: key.frame.midY - image.size.height / 2))
        }
      } else if key.value.hasPrefix("style:"), let style = TextStyle(rawValue: String(key.value.dropFirst(6))) {
        let sample = CGRect(x: key.frame.minX, y: key.frame.minY + 3, width: key.frame.width, height: key.frame.height - 17)
        drawText(title, in: sample, color: ink, size: 19)
        let caption = CGRect(x: key.frame.minX, y: key.frame.maxY - 15, width: key.frame.width, height: 12)
        drawText(style.keyboardTitle, in: caption, color: ink.withAlphaComponent(0.8), size: 9)
      } else {
        drawText(title, in: key.frame, color: ink, size: size)
      }
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
    alternatives = holdAlternatives(for: value)
    guard !alternatives.isEmpty else { return }
    alternativeIndex = 0
    showPopup(index: i, options: alternatives)
  }
  public func holdAlternatives(for value: String) -> [String] {
    if value == "styles" { return TextStyle.shortcutCases.map { "style:" + $0.rawValue } }
    if value == "style:gothic" { return ["style:gothic", "style:gothicBold"] }
    if value == "style:ransom" { return ["style:ransom", "style:SpongeBob"] }
    let title = label(value)
    var alternatives = Accents.accents(for: title)
    if alternatives.isEmpty { alternatives = NumbersAndSymbols.altSymbols(for: value) }
    if value == ".", keyboardType == .URL || keyboardType == .emailAddress {
      alternatives = [".com", ".net", ".edu", ".org"]
    }
    if let index = Array("qwertyuiop").firstIndex(of: value.first ?? " "), page == 0 {
      alternatives.insert(String(Array("1234567890")[index]), at: 0)
    }
    if value == "-" { alternatives.append(dashesMode ? "Spaces" : "Dashes") }
    return alternatives
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
        if preview && !keys[i].special && keys[i].value != " " {
          showPopup(index: i, options: [label(keys[i].value)])
        } else { popup.isHidden = true }
        setNeedsDisplay()
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
    let expandsLeft = frame.midX > parent.bounds.width / 2 && options.count > 1
    let displayed = expandsLeft ? Array(options.reversed()) : options
    if options.count > 1 { alternatives = displayed; alternativeIndex = expandsLeft ? displayed.count - 1 : 0 }
    popup.configure(keyFrame: frame, options: displayed.map { $0.hasPrefix("style:") ? label($0) : $0 }, parentWidth: parent.bounds.width, dark: dark)
    popup.selected = alternativeIndex
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
  let naturalWidth = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size)]).width
  let fittingSize = size * min(1, max(1, rect.width - 6) / max(1, naturalWidth))
  let attrs: [NSAttributedString.Key: Any] = [
    .font: UIFont.systemFont(ofSize: fittingSize), .foregroundColor: color,
  ]
  let measured = (text as NSString).size(withAttributes: attrs)
  (text as NSString).draw(
    at: CGPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2),
    withAttributes: attrs)
}
final class KeyboardPopupView: UIView {
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
      let available = keyFrame.midX > parentWidth / 2 ? keyFrame.maxX - 3 : parentWidth - keyFrame.minX - 3
      let width = min(available, CGFloat(options.count) * max(32, key.width, options.contains(where: { $0.count > 4 }) ? 68 : 0))
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
    KeyboardAppearance.key(dark: dark).setFill()
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
        size: text.count > 4 ? 15 : options.count > 1 ? 22 : 30)
    }
  }
}

private extension TextStyle {
  var keyboardTitle: String {
    switch self {
    case .boldItalic: return "Bold italic"
    case .underscore: return "Underline"
    case .strikethrough: return "Strike"
    case .inverseBoxed: return "Filled"
    case .doubleStroke: return "Double"
    case .superscript: return "Raised"
    case .gothicBold: return "Gothic bold"
    default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
  }
}
