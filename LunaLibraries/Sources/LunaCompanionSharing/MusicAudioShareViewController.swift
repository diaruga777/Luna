import UIKit
import UniformTypeIdentifiers
import AVFoundation
@_exported import LunaMusicSharing

open class MusicAudioShareViewController: CompanionShareViewController {
    /// Containing app supplies security-scoped URLs for Open In; extensions use providers.
    public var sourceURLs: [URL] = []
    public var resolveYouTube: ((String) async throws -> MusicYouTubeShare.Resolved)?
    private var youtube: MusicYouTubeShare.Resolved?
    private var isLink = false
    private let mode = UISegmentedControl(items: ["Song", "Podcast"])
    private let destinations = UIStackView()
    private var titleField: UITextField!
    private var playlistField: UITextField!
    private var choices = CompanionShareChoices()
    private var selected: Set<String> = []
    private var audioList: String?
    private var files: [URL] = []
    private var temporary: [URL] = []
    private var actions: [UIButton] = []
    open override func viewDidLoad() {
        super.viewDidLoad(); heading("Add to Luna Music")
        mode.selectedSegmentIndex = 1; stack.addArrangedSubview(mode)
        mode.addAction(UIAction { [weak self] _ in self?.updateMode() }, for: .valueChanged)
        titleField = field("Title (optional)")
        destinations.axis = .vertical; destinations.spacing = 8; stack.addArrangedSubview(destinations)
        playlistField = field("New playlist (optional)")
        actions = [button("Save") { [weak self] in self?.saveAudio(next: false) },
                   button("Add to Queue") { [weak self] in self?.saveAudio(next: false) },
                   button("Play Next") { [weak self] in self?.saveAudio(next: true) }]
        actions.forEach { $0.isEnabled = false }; stack.addArrangedSubview(status); cancelButton()
        Task { @MainActor in
            do {
                choices = try CompanionShareInbox.production("music").choices(); updateMode()
                if sourceURLs.isEmpty {
                    let providers = SharedInput.providers(in: extensionContext)
                    if !providers.isEmpty, providers.allSatisfy({
                        $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                    }), !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                        isLink = true; mode.selectedSegmentIndex = 1; updateMode()
                        let text = try await SharedInput.text(in: extensionContext)
                        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                        let links = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
                        guard links.count == 1, let input = links.first, let resolveYouTube else { throw MusicYouTubeShare.unsupported() }
                        status.text = "Checking link…"
                        youtube = try await resolveYouTube(input.absoluteString)
                        status.text = youtube?.metadata.title
                        actions.forEach { $0.isEnabled = true }
                        return
                    }
                    for provider in providers {
                        let file = try await SharedInput.file(provider, conformingTo: .audio)
                        files.append(file); temporary.append(file.deletingLastPathComponent())
                    }
                } else { files = sourceURLs }
                guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
                for file in files {
                    let access = file.startAccessingSecurityScopedResource()
                    defer { if access { file.stopAccessingSecurityScopedResource() } }
                    guard UTType(filenameExtension: file.pathExtension)?.conforms(to: .audio) == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                    let duration = try await AVURLAsset(url: file).load(.duration).seconds
                    guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                }
                status.text = files.map(\.lastPathComponent).joined(separator: "\n")
                actions.forEach { $0.isEnabled = true }
            } catch { status.text = isLink ? MusicYouTubeShare.unsupportedMessage : error.localizedDescription }
        }
        updateMode()
    }
    private func updateMode() {
        let podcast = mode.selectedSegmentIndex == 1
        mode.isHidden = isLink
        destinations.isHidden = isLink
        playlistField.isHidden = podcast || isLink
        actions.enumerated().forEach { $0.element.isHidden = podcast ? $0.offset == 0 : $0.offset != 0 }
        for view in destinations.arrangedSubviews { view.removeFromSuperview() }
        if podcast { addChoice(id: "", title: "Imported Audio", checked: audioList == nil) }
        for choice in podcast ? choices.audioLists : choices.playlists {
            addChoice(id: choice.id, title: choice.title, checked: podcast ? audioList == choice.id : selected.contains(choice.id))
        }
    }
    private func addChoice(id: String, title: String, checked: Bool) {
        var config = UIButton.Configuration.tinted(); config.title = title
        config.image = UIImage(systemName: checked ? "checkmark.circle.fill" : "circle")
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if mode.selectedSegmentIndex == 1 { audioList = id.isEmpty ? nil : id }
            else if !selected.insert(id).inserted { selected.remove(id) }
            updateMode()
        })
        button.accessibilityTraits = checked ? [.button, .selected] : [.button]
        destinations.addArrangedSubview(button)
    }
    private func saveAudio(next: Bool) {
        if let youtube {
            performSave { [self] in
                try MusicYouTubeShare.start(youtube, title: titleField.text ?? "", next: next, choices: choices,
                                            inbox: CompanionShareInbox.production("music"))
            }
            return
        }
        let podcast = mode.selectedSegmentIndex == 1
        let names = files.enumerated().map { "\($0.offset)-" + $0.element.lastPathComponent }
        let capture = CompanionShareCapture(kind: podcast ? .podcast : .song, title: titleField.text ?? "",
            filenames: names, destinations: podcast ? audioList.map { [$0] } ?? [] : selected.sorted(),
            newPlaylist: playlistField.text ?? "", playNext: next)
        performSave { [self] in try CompanionShareInbox.production("music").save(capture, files: files) }
    }
    deinit { for directory in temporary { try? FileManager.default.removeItem(at: directory) } }
}
