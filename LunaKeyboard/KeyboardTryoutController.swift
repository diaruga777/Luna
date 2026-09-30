import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

final class KeyboardTryoutController: UIViewController, UITextViewDelegate {
  private let editor = UITextView()
  private let surface = KeyboardSurface()
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
    NSLayoutConstraint.activate([
      editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      editor.bottomAnchor.constraint(equalTo: surface.topAnchor),
    ])
    surface.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      surface.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
    let height = surface.heightAnchor.constraint(equalToConstant: 264)
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
    surface.insert = { [weak self] in self?.editor.insertText($0) }
    surface.delete = { [weak self] in self?.editor.deleteBackward() }
    surface.moveCursor = { [weak self] offset in
      guard let self, let selected = self.editor.selectedTextRange,
        let position = self.editor.position(from: selected.start, offset: offset)
      else { return }
      self.editor.selectedTextRange = self.editor.textRange(from: position, to: position)
    }
    surface.store = KeyboardStore()
    surface.hasFullAccess = true
    surface.board.needsGlobe = false
    surface.board.dark = true
    surface.reloadSettings()
    editor.inputView = input
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    editor.becomeFirstResponder()
  }
  func textViewDidChange(_ textView: UITextView) { surface.refresh() }
  func textViewDidChangeSelection(_ textView: UITextView) { surface.refresh() }
  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    surface.releaseMemory()
  }
}
