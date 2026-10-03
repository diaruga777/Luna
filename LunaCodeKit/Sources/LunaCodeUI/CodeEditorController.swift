#if os(iOS)
import UIKit
import Runestone
import TreeSitterSwiftRunestone
import TreeSitterJSONRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterCRunestone
import LunaCodeCore

@MainActor final class CodeEditorController: UIViewController, TextViewDelegate, UITableViewDataSource, UITableViewDelegate {
    private final class Document {
        var draft: CodeDraft
        let view: CodeTextView
        let peer: String
        var remote: CodeDocument?
        var diagnostics: [CodeDiagnostic] = []
        var generation = 0
        init(draft: CodeDraft, view: CodeTextView, peer: String) { self.draft = draft; self.view = view; self.peer = peer }
    }
    private struct Pair: CharacterPair { let leading: String; let trailing: String }
    private let environment: CodeEnvironment
    private var documents: [Document] = []
    private var active: Document?
    private let container = UIView()
    private let tabs = UIScrollView()
    private let tabStack = UIStackView()
    private let status = UIButton(type: .system)
    private let positionLabel = UILabel()
    private let footer = UIStackView()
    private let empty = UIStackView()
    private let completionTable = UITableView()
    private var completions: [CodeCompletion] = []
    private var completionIndex = 0
    private var completionGeneration = 0
    private var completionPath = ""
    private var completionSelection = NSRange(location: 0, length: 0)
    private var analysis: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var poll: Timer?
    private var polling = false
    private var saving = false
    private var job: CodeJob?
    private var fontSize: CGFloat
    private var saveButton: UIBarButtonItem!
    private var buildButton: UIBarButtonItem!
    var openFiles: (() -> Void)?

    init(environment: CodeEnvironment) {
        self.environment = environment
        let size = environment.defaults.double(forKey: "Code.fontSize")
        fontSize = size > 0 ? size : 15
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { poll?.invalidate(); analysis?.cancel(); completionTask?.cancel(); draftTask?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        title = "Luna Code"; navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain, target: self, action: #selector(files))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Project Files"
        saveButton = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(saveAction))
        saveButton.accessibilityLabel = "Save to Mac"; saveButton.isEnabled = false
        buildButton = UIBarButtonItem(image: UIImage(systemName: "hammer"), menu: buildMenu())
        buildButton.accessibilityLabel = "Build and Deploy"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: editorMenu())
        more.accessibilityLabel = "Editor Actions"
        navigationItem.rightBarButtonItems = [more, buildButton, saveButton]
        tabStack.axis = .horizontal; tabStack.spacing = 4; tabStack.alignment = .fill
        tabs.addSubview(tabStack); tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabs.showsHorizontalScrollIndicator = false; tabs.backgroundColor = .secondarySystemBackground
        NSLayoutConstraint.activate([
            tabStack.topAnchor.constraint(equalTo: tabs.contentLayoutGuide.topAnchor), tabStack.bottomAnchor.constraint(equalTo: tabs.contentLayoutGuide.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabs.contentLayoutGuide.leadingAnchor, constant: 8), tabStack.trailingAnchor.constraint(equalTo: tabs.contentLayoutGuide.trailingAnchor, constant: -8),
            tabStack.heightAnchor.constraint(equalTo: tabs.frameLayoutGuide.heightAnchor)
        ])
        status.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
        status.contentHorizontalAlignment = .leading; status.setTitle("Ready", for: .normal)
        status.addTarget(self, action: #selector(showIssues), for: .touchUpInside)
        positionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); positionLabel.textColor = .secondaryLabel
        footer.axis = .horizontal; footer.spacing = 12; footer.addArrangedSubview(status); footer.addArrangedSubview(positionLabel)
        footer.isLayoutMarginsRelativeArrangement = true; footer.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        footer.backgroundColor = .secondarySystemBackground
        let vertical = UIStackView(arrangedSubviews: [tabs, container, footer]); vertical.axis = .vertical
        vertical.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(vertical)
        NSLayoutConstraint.activate([
            vertical.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor), vertical.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            vertical.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), vertical.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 34), footer.heightAnchor.constraint(equalToConstant: 24)
        ])
        let symbol = UIImageView(image: UIImage(systemName: "curlybraces")); symbol.tintColor = .systemIndigo; symbol.contentMode = .scaleAspectFit
        symbol.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let heading = UILabel(); heading.text = "Your Mac. Your code."; heading.font = .systemFont(ofSize: 25, weight: .semibold); heading.textAlignment = .center
        let detail = UILabel(); detail.text = "Open a source file from your Mac.\nDrafts stay here until you save."
        detail.font = .preferredFont(forTextStyle: .body); detail.textColor = .secondaryLabel; detail.numberOfLines = 0; detail.textAlignment = .center
        let browse = UIButton(type: .system); browse.setTitle("Browse Mac Files", for: .normal); browse.configuration = .tinted(); browse.addTarget(self, action: #selector(files), for: .touchUpInside)
        empty.axis = .vertical; empty.spacing = 16; [symbol, heading, detail, browse].forEach { empty.addArrangedSubview($0) }
        empty.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: container.centerXAnchor), empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40)])
        completionTable.dataSource = self; completionTable.delegate = self; completionTable.rowHeight = 40
        completionTable.layer.cornerRadius = 10; completionTable.layer.borderWidth = 0.5; completionTable.layer.borderColor = UIColor.separator.cgColor
        completionTable.backgroundColor = .secondarySystemBackground; completionTable.isHidden = true
        container.addSubview(completionTable)
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
        foreground()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let low = view.bounds.height < 430
        tabs.isHidden = documents.count < 2 || (low && view.keyboardLayoutGuide.layoutFrame.height > 80)
        footer.isHidden = low && view.keyboardLayoutGuide.layoutFrame.height > 80
        placeCompletions()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        let range = active?.view.selectedRange
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout() }) { _ in
            if let range { self.active?.view.scrollRangeToVisible(range) }
        }
    }
    @objc private func files() { openFiles?() }
    @objc private func background() { persistAll(); poll?.invalidate(); poll = nil; analysis?.cancel(); hideCompletions() }
    @objc private func foreground() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in await self?.refreshRemote() } }
        if let id = environment.defaults.string(forKey: "Code.job." + environment.peerID()) { Task { await refreshJob(id) } }
    }
    func open(path: String) {
        loadViewIfNeeded()
        if let existing = documents.first(where: { $0.draft.base.path == path && $0.peer == environment.peerID() }) { activate(existing); return }
        Task {
            do {
                let peer = environment.peerID()
                let cached = try environment.drafts.load(peer: peer, path: path)
                if let cached { install(cached, peer: peer) }
                let response = try await environment.client.call(CodeRequest(.open, path: path))
                guard let remote = response.document, environment.peerID() == peer else { return }
                if let document = documents.first(where: { $0.draft.base.path == path && $0.peer == peer }) { acceptRemote(remote, for: document) }
                else { install(CodeDraft(base: remote), peer: peer) }
            } catch { if active?.draft.base.path == path { setStatus("Offline · draft on iPhone", color: .systemOrange) } else { showError(error) } }
        }
    }
    private func install(_ draft: CodeDraft, peer: String) {
        let editor = CodeTextView(); editor.translatesAutoresizingMaskIntoConstraints = false
        editor.editorDelegate = self; editor.backgroundColor = .systemBackground
        editor.showLineNumbers = true; editor.lineHeightMultiplier = 1.22; editor.isFindInteractionEnabled = true
        editor.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 32, right: 16)
        editor.isLineWrappingEnabled = environment.defaults.object(forKey: "Code.wrap") as? Bool ?? true
        editor.autocorrectionType = .no; editor.autocapitalizationType = .none; editor.spellCheckingType = .no
        editor.smartQuotesType = .no; editor.smartDashesType = .no; editor.smartInsertDeleteType = .no
        editor.characterPairs = [Pair(leading: "(", trailing: ")"), Pair(leading: "[", trailing: "]"), Pair(leading: "{", trailing: "}"), Pair(leading: "\"", trailing: "\"")]
        editor.keyboardDismissMode = .interactive
        let state = makeState(text: draft.text, path: draft.base.path)
        editor.setState(state)
        if let endings = state.detectedLineEndings { editor.lineEndings = endings }
        switch state.detectedIndentStrategy { case .tab: editor.indentStrategy = .tab(length: 4); case .space(let length): editor.indentStrategy = .space(length: length); case .unknown: editor.indentStrategy = .space(length: 4) }
        editor.selectedRange = NSRange(location: min(draft.selection, (draft.text as NSString).length), length: 0)
        editor.inputAccessoryView = accessory(for: editor)
        editor.completionCommand = { [weak self] key in self?.completionKey(key) }
        let document = Document(draft: draft, view: editor, peer: peer)
        container.insertSubview(editor, belowSubview: completionTable)
        NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: container.leadingAnchor), editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.topAnchor.constraint(equalTo: container.topAnchor), editor.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        documents.append(document); activate(document); persist(document)
    }
    private func makeState(text: String, path: String) -> TextViewState {
        let theme = CodeTheme(size: fontSize)
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return TextViewState(text: text, theme: theme, language: .swift)
        case "json", "xcstrings": return TextViewState(text: text, theme: theme, language: .json)
        case "js", "jsx": return TextViewState(text: text, theme: theme, language: .javaScript)
        case "c", "h", "m", "mm", "cpp", "hpp": return TextViewState(text: text, theme: theme, language: .c)
        default: return TextViewState(text: text, theme: theme)
        }
    }
    private func activate(_ document: Document) {
        environment.defaults.set(document.draft.base.path, forKey: "Code.lastFile." + document.peer)
        if let active { persist(active) }
        let editing = active?.view.isFirstResponder == true
        active?.view.resignFirstResponder(); analysis?.cancel(); hideCompletions(); active = document
        for item in documents { item.view.isHidden = item !== document }
        empty.isHidden = true; title = (document.draft.base.path as NSString).lastPathComponent
        if editing { document.view.becomeFirstResponder() }
        updateChrome(); scheduleAnalysis(); view.setNeedsLayout()
    }
    private func updateChrome() {
        tabStack.arrangedSubviews.forEach { tabStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for doc in documents {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.title = (doc.draft.modified ? "● " : "") + (doc.draft.base.path as NSString).lastPathComponent
            configuration.baseForegroundColor = doc === active ? .label : .secondaryLabel
            configuration.background.backgroundColor = doc === active ? .systemBackground : .clear
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
            button.configuration = configuration; button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            button.addAction(UIAction { [weak self, weak doc] _ in if let doc { self?.activate(doc) } }, for: .touchUpInside)
            tabStack.addArrangedSubview(button)
        }
        saveButton.isEnabled = active?.draft.modified == true && !saving
        guard let active else { return }
        let pos = CodePosition.at(utf16Offset: active.view.selectedRange.location, in: active.view.text)
        positionLabel.text = "\(pos.line + 1):\(pos.character + 1)"
        if active.remote != nil { setStatus("Mac changed · Choose a version", color: .systemOrange) }
        else if active.draft.modified { setStatus("Edited · saved on iPhone", color: .secondaryLabel) }
        else { setStatus("Saved to Mac", color: .secondaryLabel) }
    }
    private func setStatus(_ message: String, color: UIColor = .secondaryLabel) { status.setTitle(message, for: .normal); status.setTitleColor(color, for: .normal); status.accessibilityLabel = message }
    func textView(_ textView: TextView, canReplaceTextIn highlightedRange: HighlightedRange) -> Bool { true }
    func textViewDidChange(_ textView: TextView) {
        guard let doc = documents.first(where: { $0.view === textView }) else { return }
        doc.draft.text = textView.text; doc.draft.selection = textView.selectedRange.location; doc.generation += 1
        hideCompletions(); updateChrome(); scheduleAnalysis()
        draftTask?.cancel(); draftTask = Task { [weak self, weak doc] in
            try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled, let self, let doc else { return }; self.persist(doc)
        }
        let offset = textView.selectedRange.location
        if environment.project != nil, offset > 0 {
            let last = (textView.text as NSString).substring(with: NSRange(location: offset - 1, length: 1))
            if last == "." || last.rangeOfCharacter(from: .alphanumerics) != nil { requestCompletion() }
        }
    }
    func textViewDidChangeSelection(_ textView: TextView) {
        guard active?.view === textView else { return }
        if !completionTable.isHidden, textView.selectedRange != completionSelection { hideCompletions() }
        active?.draft.selection = textView.selectedRange.location
        let pos = CodePosition.at(utf16Offset: textView.selectedRange.location, in: textView.text)
        positionLabel.text = "\(pos.line + 1):\(pos.character + 1)"
    }
    private func persist(_ doc: Document) {
        do { try environment.drafts.save(doc.draft, peer: doc.peer) }
        catch { setStatus("Draft could not be saved", color: .systemRed) }
    }
    private func persistAll() { for doc in documents { persist(doc) } }
    @objc private func saveAction() { Task { _ = await saveActive() } }
    private func saveActive() async -> Bool {
        guard let doc = active else { return true }
        guard doc.peer == environment.peerID() else { showError(CodeFailure("This draft belongs to a different Mac. Reconnect that Mac before saving.")); return false }
        if !doc.draft.modified { return true }
        guard !saving else { return false }; saving = true; saveButton.isEnabled = false
        defer { saving = false; updateChrome() }
        persist(doc)
        let submitted = doc.draft.text
        var request = CodeRequest(.save, path: doc.draft.base.path); request.text = submitted; request.version = doc.draft.base.version
        do {
            let response = try await environment.client.call(request)
            guard let remote = response.document else { throw CodeFailure("The Mac did not acknowledge the saved file.") }
            if response.conflict { doc.remote = remote; resolveConflict(doc); return false }
            doc.draft.base = remote; doc.remote = nil; persist(doc)
            return true
        } catch { showError(error); return false }
    }
    private func acceptRemote(_ remote: CodeDocument, for doc: Document) {
        guard remote.version != doc.draft.base.version else { return }
        if doc.draft.modified { doc.remote = remote; if active === doc { updateChrome() }; return }
        let selection = doc.view.selectedRange; let offset = doc.view.contentOffset
        doc.draft = CodeDraft(base: remote, selection: min(selection.location, (remote.text as NSString).length))
        doc.view.setState(makeState(text: remote.text, path: remote.path), addUndoAction: true)
        doc.view.selectedRange = NSRange(location: doc.draft.selection, length: 0); doc.view.contentOffset = offset
        doc.generation += 1; persist(doc)
        if active === doc { updateChrome(); scheduleAnalysis() }
    }
    private func resolveConflict(_ doc: Document) {
        guard let remote = doc.remote else { return }
        let alert = UIAlertController(title: "This file changed on your Mac", message: "Choose which version to keep. Your iPhone draft remains saved until you choose.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Use Mac Version", style: .destructive) { [weak self] _ in
            guard let self else { return }; doc.draft = CodeDraft(base: remote); doc.remote = nil
            doc.view.setState(self.makeState(text: remote.text, path: remote.path), addUndoAction: true); doc.generation += 1
            self.persist(doc); self.updateChrome(); self.scheduleAnalysis()
        })
        alert.addAction(UIAlertAction(title: "Use iPhone Version", style: .default) { [weak self] _ in
            guard let self else { return }; doc.draft.base = remote; doc.remote = nil; self.persist(doc)
            Task { _ = await self.saveActive() }
        })
        present(alert, animated: true)
    }
    private func refreshRemote() async {
        guard !polling, UIApplication.shared.applicationState == .active else { return }
        polling = true; defer { polling = false }
        if let job, job.state == .running { await refreshJob(job.id) }
        guard let doc = active, !saving, doc.peer == environment.peerID() else { return }
        do {
            var request = CodeRequest(.open, path: doc.draft.base.path); request.version = doc.draft.base.version
            let response = try await environment.client.call(request)
            if let remote = response.document { acceptRemote(remote, for: doc) }
        } catch { if active === doc { setStatus("Mac unavailable · draft on iPhone", color: .systemOrange) } }
    }
    private func scheduleAnalysis() {
        analysis?.cancel()
        guard let doc = active else { return }
        let generation = doc.generation; let text = doc.draft.text; let path = doc.draft.base.path
        analysis = Task { [weak self, weak doc] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let doc else { return }
            let local = path.hasSuffix(".swift") ? await Task.detached(priority: .utility) { CodeSyntax.diagnostics(text: text) }.value : []
            guard !Task.isCancelled, doc.generation == generation else { return }
            self.showDiagnostics(local, doc: doc, local: true)
            guard let project = self.environment.project else { return }
            var request = CodeRequest(.analyze, path: path); request.project = project; request.text = text
            request.bufferVersion = Int(Date().timeIntervalSince1970 * 1000)
            do {
                let response = try await self.environment.client.call(request)
                guard !Task.isCancelled, doc.generation == generation else { return }
                self.showDiagnostics(response.diagnostics, doc: doc, local: false)
            } catch { if !Task.isCancelled, self.active === doc, local.isEmpty { self.setStatus("Local syntax OK · Mac checks unavailable", color: .systemOrange) } }
        }
    }
    private func showDiagnostics(_ diagnostics: [CodeDiagnostic], doc: Document, local: Bool) {
        doc.diagnostics = diagnostics
        doc.view.highlightedRanges = diagnostics.compactMap { diagnostic in
            guard let location = CodePosition(line: diagnostic.line, character: diagnostic.character).offset(in: doc.view.text) else { return nil }
            let length = min(1, (doc.view.text as NSString).length - location)
            return HighlightedRange(range: NSRange(location: location, length: length), color: (diagnostic.severity == 1 ? UIColor.systemRed : .systemOrange).withAlphaComponent(0.25))
        }
        guard active === doc, doc.remote == nil else { return }
        setStatus(diagnostics.isEmpty ? (local ? "Local syntax OK" : "Mac checks passed") + (doc.draft.modified ? " · Edited" : "") : "\(diagnostics.count) issue\(diagnostics.count == 1 ? "" : "s") · \(local ? "Syntax" : "Mac")", color: diagnostics.isEmpty ? .secondaryLabel : .systemOrange)
    }
    @objc private func showIssues() {
        if let doc = active, doc.remote != nil { resolveConflict(doc); return }
        guard let doc = active, !doc.diagnostics.isEmpty else { if job != nil { showBuildLog() }; return }
        let list = CodeListController(title: "Issues", rows: doc.diagnostics.map { "Line \($0.line + 1) · \($0.message)" }) { [weak self, weak doc] index in
            guard let self, let doc else { return }; self.dismiss(animated: true); _ = doc.view.goToLine(doc.diagnostics[index].line); doc.view.becomeFirstResponder()
        }
        present(UINavigationController(rootViewController: list), animated: true)
    }
    @objc private func requestCompletion() {
        guard let doc = active, let project = environment.project else { setStatus("Select a project for completion", color: .systemOrange); return }
        completionTask?.cancel(); let generation = doc.generation; let selection = doc.view.selectedRange
        var request = CodeRequest(.complete, path: doc.draft.base.path); request.text = doc.draft.text; request.project = project
        request.position = CodePosition.at(utf16Offset: selection.location, in: request.text); request.bufferVersion = Int(Date().timeIntervalSince1970 * 1000)
        completionTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let response = try await environment.client.call(request)
                guard !Task.isCancelled, active === doc, doc.generation == generation, doc.view.selectedRange == selection else { return }
                completions = response.completions; completionIndex = 0; completionGeneration = generation; completionPath = doc.draft.base.path; completionSelection = selection
                completionTable.reloadData(); completionTable.isHidden = completions.isEmpty; doc.view.hasCompletions = !completions.isEmpty
                if completions.isEmpty { setStatus("No completions · Build to refresh index") }
                else { completionTable.selectRow(at: IndexPath(row: 0, section: 0), animated: false, scrollPosition: .top); placeCompletions() }
            } catch { if !Task.isCancelled { setStatus("Completion unavailable · Prepare project", color: .systemOrange) } }
        }
    }
    private func hideCompletions() { completionTask?.cancel(); completionTable.isHidden = true; active?.view.hasCompletions = false; completions = [] }
    private func placeCompletions() {
        guard !completionTable.isHidden, let editor = active?.view, let range = editor.selectedTextRange else { return }
        let caret = editor.convert(editor.caretRect(for: range.end), to: container)
        let width = min(430, max(220, container.bounds.width - 24))
        let height = min(CGFloat(completions.count) * 40, max(40, min(200, container.bounds.height * 0.48)))
        let below = caret.maxY + 5
        let y = below + height <= container.bounds.height ? below : max(0, caret.minY - height - 5)
        completionTable.frame = CGRect(x: max(8, min(caret.minX, container.bounds.width - width - 8)), y: y, width: width, height: height)
    }
    private func completionKey(_ key: String) {
        if key == UIKeyCommand.inputEscape { hideCompletions(); return }
        if key == "\r" || key == "\t" { insertCompletion(completionIndex); return }
        completionIndex = max(0, min(completions.count - 1, completionIndex + (key == UIKeyCommand.inputDownArrow ? 1 : -1)))
        completionTable.selectRow(at: IndexPath(row: completionIndex, section: 0), animated: true, scrollPosition: .middle)
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { completions.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil); let completion = completions[indexPath.row]
        cell.textLabel?.text = completion.label; cell.textLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        cell.detailTextLabel?.text = completion.detail; cell.detailTextLabel?.font = .systemFont(ofSize: 10); return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { insertCompletion(indexPath.row) }
    private func insertCompletion(_ index: Int) {
        guard let doc = active, completions.indices.contains(index), doc.generation == completionGeneration, doc.draft.base.path == completionPath, doc.view.selectedRange == completionSelection else { hideCompletions(); return }
        let item = completions[index]; var range = doc.view.selectedRange
        if let start = item.start?.offset(in: doc.view.text), let end = item.end?.offset(in: doc.view.text), end >= start { range = NSRange(location: start, length: end - start) }
        hideCompletions(); doc.view.replace(range, withText: item.text)
        doc.view.selectedRange = NSRange(location: range.location + (item.text as NSString).length, length: 0)
        textViewDidChange(doc.view)
    }
    private func accessory(for editor: CodeTextView) -> UIView {
        let accessory = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 40), inputViewStyle: .keyboard)
        let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(scroll)
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 2; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        func button(_ title: String, label: String? = nil, action: @escaping () -> Void) {
            let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.titleLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
            b.accessibilityLabel = label ?? title; b.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            b.addAction(UIAction { _ in action() }, for: .touchUpInside); stack.addArrangedSubview(b)
        }
        button("⇥", label: "Indent") { [weak editor] in editor?.shiftRight() }
        button("⇤", label: "Outdent") { [weak editor] in editor?.shiftLeft() }
        button("↶", label: "Undo") { [weak editor] in editor?.undoManager?.undo() }
        button("↷", label: "Redo") { [weak editor] in editor?.undoManager?.redo() }
        for symbol in ["{", "}", "(", ")", "[", "]", "\"", ".", ":", "=", "_"] { button(symbol) { [weak editor] in editor?.insertText(symbol) } }
        button("⌘", label: "Code Completion") { [weak self] in self?.requestCompletion() }
        button("⌄", label: "Dismiss Keyboard") { [weak editor] in editor?.resignFirstResponder() }
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: accessory.safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: accessory.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: accessory.topAnchor), scroll.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)])
        return accessory
    }
    private func editorMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Find & Replace", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.findInFile() },
            UIAction(title: "Code Completion", image: UIImage(systemName: "text.cursor")) { [weak self] _ in self?.requestCompletion() },
            UIAction(title: "Toggle Comment", image: UIImage(systemName: "text.bubble")) { [weak self] _ in self?.comment() },
            UIAction(title: "Toggle Line Wrapping", image: UIImage(systemName: "arrow.turn.down.left")) { [weak self] _ in self?.wrap() },
            UIAction(title: "Larger Text", image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in self?.resize(1) },
            UIAction(title: "Smaller Text", image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in self?.resize(-1) },
            UIAction(title: "Open File…", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in self?.quickOpen() },
            UIAction(title: "Acknowledgements", image: UIImage(systemName: "info.circle")) { [weak self] _ in self?.acknowledgements() },
            UIAction(title: "Close File", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.closeFile() }
        ])
    }
    private func acknowledgements() {
        let controller = UIViewController(); controller.title = "Acknowledgements"
        let text = UITextView(); text.isEditable = false; text.font = .preferredFont(forTextStyle: .footnote)
        text.text = Bundle.module.url(forResource: "Acknowledgements", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        controller.view = text
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        present(UINavigationController(rootViewController: controller), animated: true)
    }
    private func buildMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Build", image: UIImage(systemName: "hammer")) { [weak self] _ in self?.startJob(.build) },
            UIAction(title: "Build & Deploy to TestFlight", image: UIImage(systemName: "paperplane")) { [weak self] _ in self?.startJob(.deploy) },
            UIAction(title: "Prepare Code Intelligence", image: UIImage(systemName: "text.badge.checkmark")) { [weak self] _ in self?.startJob(.prepare) },
            UIAction(title: "Project Settings", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.configureProject() },
            UIAction(title: "Build Log", image: UIImage(systemName: "terminal")) { [weak self] _ in self?.showBuildLog() },
            UIAction(title: "Cancel Build", image: UIImage(systemName: "stop")) { [weak self] _ in self?.cancelJob() }
        ])
    }
    @objc private func findInFile() { active?.view.findInteraction?.presentFindNavigator(showingReplace: true) }
    @objc private func wrap() { guard let editor = active?.view else { return }; editor.isLineWrappingEnabled.toggle(); environment.defaults.set(editor.isLineWrappingEnabled, forKey: "Code.wrap") }
    private func resize(_ amount: CGFloat) { fontSize = max(11, min(28, fontSize + amount)); environment.defaults.set(fontSize, forKey: "Code.fontSize"); documents.forEach { $0.view.theme = CodeTheme(size: fontSize) } }
    @objc private func comment() {
        guard let editor = active?.view else { return }
        let ns = editor.text as NSString; let range = ns.lineRange(for: editor.selectedRange)
        let lines = ns.substring(with: range).components(separatedBy: "\n")
        let uncomment = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let changed = lines.map { line -> String in
            if line.isEmpty { return line }
            let prefix = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let rest = String(line.dropFirst(prefix.count))
            return prefix + (uncomment && rest.hasPrefix("//") ? String(rest.dropFirst(2)).replacingOccurrences(of: "^ ", with: "", options: .regularExpression) : "// " + rest)
        }.joined(separator: "\n")
        editor.replace(range, withText: changed); textViewDidChange(editor)
    }
    @objc private func quickOpen() {
        let alert = UIAlertController(title: "Open Source File", message: "Enter its absolute path on your Mac.", preferredStyle: .alert)
        alert.addTextField { $0.text = self.environment.project?.root.appending("/"); $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in if let path = alert.textFields?.first?.text { self?.open(path: path) } })
        present(alert, animated: true)
    }
    @objc private func closeFile() {
        guard let doc = active else { return }; persist(doc)
        doc.view.resignFirstResponder(); doc.view.removeFromSuperview(); documents.removeAll { $0 === doc }; active = nil
        if let next = documents.last { activate(next) } else { title = "Luna Code"; empty.isHidden = false; updateChrome(); view.setNeedsLayout() }
    }
    func configureProject() {
        let alert = UIAlertController(title: "Project Settings", message: "Choose the Xcode project and scheme. App and internal group IDs are needed only for TestFlight. API credentials stay on your Mac.", preferredStyle: .alert)
        let current = environment.project
        for (placeholder, value) in [("/path/App.xcodeproj or .xcworkspace", current?.path), ("Scheme", current?.scheme), ("App Store Connect app ID", current?.appID), ("Internal testing group ID", current?.groupID)] {
            alert.addTextField { $0.placeholder = placeholder; $0.text = value; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self, let fields = alert.textFields else { return }
            self.environment.project = CodeProject(path: fields[0].text ?? "", scheme: fields[1].text ?? "", appID: fields[2].text ?? "", groupID: fields[3].text ?? "")
            if self.environment.project?.scheme.isEmpty == true { self.chooseScheme() } else { self.scheduleAnalysis() }
        })
        present(alert, animated: true)
    }
    private func chooseScheme() {
        guard let project = environment.project else { return }
        setStatus("Reading Xcode schemes…")
        Task {
            do {
                let response = try await environment.client.call(CodeRequest(.schemes, path: project.path))
                let list = CodeListController(title: "Choose Scheme", rows: response.schemes) { [weak self] index in
                    self?.environment.project?.scheme = response.schemes[index]; self?.dismiss(animated: true); self?.scheduleAnalysis()
                }
                present(UINavigationController(rootViewController: list), animated: true)
            } catch { showError(error) }
        }
    }
    private func startJob(_ operation: CodeRequest.Operation) {
        guard environment.project != nil else { configureProject(); return }
        Task {
            let original = active
            for doc in documents where doc.draft.modified {
                activate(doc); guard await saveActive() else { return }
            }
            if let original { activate(original) }
            var request = CodeRequest(operation); request.project = environment.project
            do {
                let response = try await environment.client.call(request); job = response.job
                environment.defaults.set(job?.id, forKey: "Code.job." + environment.peerID()); showBuildLog()
            } catch { showError(error) }
        }
    }
    private func refreshJob(_ id: String) async {
        var request = CodeRequest(.job); request.jobID = id
        if let response = try? await environment.client.call(request) { job = response.job }
        if let log = (presentedViewController as? UINavigationController)?.topViewController as? CodeLogController { log.update(job) }
    }
    private func showBuildLog() {
        guard let job else { showError(CodeFailure("No build yet. Select a project, then choose Build or Build & Deploy.")); return }
        let log = CodeLogController(job: job); present(UINavigationController(rootViewController: log), animated: true)
    }
    private func cancelJob() {
        guard let job else { return }; var request = CodeRequest(.cancel); request.jobID = job.id
        Task { do { self.job = try await environment.client.call(request).job } catch { showError(error) } }
    }
    private func showError(_ error: Error) {
        guard presentedViewController == nil else { setStatus(error.localizedDescription, color: .systemRed); return }
        let alert = UIAlertController(title: "Luna Code", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    override var keyCommands: [UIKeyCommand]? {
        [("s", UIKeyModifierFlags.command, #selector(saveAction), "Save to Mac"),
         ("f", .command, #selector(findInFile), "Find & Replace"), ("o", [.command, .shift], #selector(quickOpen), "Open File"),
         ("/", .command, #selector(comment), "Toggle Comment"), ("w", .command, #selector(closeFile), "Close File"),
         (" ", .control, #selector(requestCompletion), "Complete Code"), ("b", .command, #selector(buildShortcut), "Build"),
         ("[", .command, #selector(outdent), "Outdent"), ("]", .command, #selector(indent), "Indent"),
         ("1", .command, #selector(files), "Project Files")].map { input, modifiers, action, title in
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action); command.discoverabilityTitle = title; command.wantsPriorityOverSystemBehavior = true; return command
         }
    }
    @objc private func buildShortcut() { startJob(.build) }
    @objc private func indent() { active?.view.shiftRight() }
    @objc private func outdent() { active?.view.shiftLeft() }
}

@MainActor final class CodeListController: UITableViewController {
    let rows: [String]; let select: (Int) -> Void
    init(title: String, rows: [String], select: @escaping (Int) -> Void) { self.rows = rows; self.select = select; super.init(style: .insetGrouped); self.title = title }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }) }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.textLabel?.text = rows[indexPath.row]; cell.textLabel?.numberOfLines = 0; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { select(indexPath.row) }
}
@MainActor final class CodeLogController: UIViewController {
    private let text = UITextView()
    private var job: CodeJob
    init(job: CodeJob) { self.job = job; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.isEditable = false; text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text); NSLayoutConstraint.activate([text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), text.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), text.leadingAnchor.constraint(equalTo: view.leadingAnchor), text.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }); update(job)
    }
    func update(_ value: CodeJob?) { guard let value else { return }; job = value; title = value.title + " · " + value.state.rawValue.capitalized; text.text = value.log.isEmpty ? "Starting on your Mac…" : value.log }
}
#endif
