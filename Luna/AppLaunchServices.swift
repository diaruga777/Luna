import UIKit

/// Services are installed after the first displayed root frame. Early user
/// actions and background entry points can demand them synchronously instead.
@MainActor
final class AppLaunchServices {
    static let shared = AppLaunchServices()
    private var installation: (() -> Void)?
    private var waiting: [() -> Void] = []
    private(set) var isReady = true
    private var isInstalling = false

    func configure(_ installation: @escaping () -> Void) {
        precondition(isReady && !isInstalling)
        self.installation = installation
        isReady = false
    }

    func whenReady(_ action: @escaping () -> Void) {
        if isReady { action() } else { waiting.append(action) }
    }

    func ensureReady() {
        guard !isReady, !isInstalling, let installation else { return }
        isInstalling = true
        installation()
        self.installation = nil
        isInstalling = false
        isReady = true
        let actions = waiting
        waiting.removeAll()
        for action in actions { action() }
    }
}

/// A main-queue async block can execute before Core Animation's first commit.
/// Two display callbacks leave a complete frame interval for the root to draw.
@MainActor
final class AppFirstFrame: NSObject {
    private var displayLink: CADisplayLink?
    private var sawFrame = false
    private let completion: () -> Void

    private init(completion: @escaping () -> Void) { self.completion = completion }

    static func perform(_ completion: @escaping () -> Void) {
        let observer = AppFirstFrame(completion: completion)
        let link = CADisplayLink(target: observer, selector: #selector(observer.tick))
        observer.displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        guard sawFrame else { sawFrame = true; return }
        displayLink?.invalidate()
        displayLink = nil
        completion()
    }
}

/// A tap arriving before deferred installation must not reach an unwired
/// save/settings action. Preserve and deliver the original event afterwards.
final class AppLaunchWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        if event.type == .presses || event.allTouches?.contains(where: { $0.phase == .began }) == true {
            AppLaunchServices.shared.ensureReady()
        }
        super.sendEvent(event)
    }
}
