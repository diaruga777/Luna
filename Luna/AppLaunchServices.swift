import UIKit

/// Foreground installation suspends while workers load the plugin platform.
/// Cached UI stays interactive; service consumers queue until it is ready.
@MainActor
final class AppLaunchServices {
    static let shared = AppLaunchServices()
    private var installation: (() -> Void)?
    private var asynchronousInstallation: (() async -> Void)?
    private var waiting: [() -> Void] = []
    private(set) var isReady = true
    private var isInstalling = false

    func configure(_ installation: @escaping () -> Void, asynchronously: (() async -> Void)? = nil) {
        precondition(isReady && !isInstalling)
        self.installation = installation
        self.asynchronousInstallation = asynchronously
        isReady = false
    }

    /// A Bluetooth relaunch has no displayed frame to trigger installation.
    /// Restore its managers before returning from didFinishLaunching.
    func restoreBluetoothIfNeeded(
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?,
        restore: () -> Void
    ) {
        guard let identifiers = launchOptions?[.bluetoothCentrals] as? [String],
              !identifiers.isEmpty else { return }
        ensureReady()
        restore()
    }

    func whenReady(_ action: @escaping () -> Void) {
        if isReady { action() } else { waiting.append(action) }
    }

    func start() {
        guard !isReady, !isInstalling else { return }
        guard let asynchronousInstallation else { ensureReady(); return }
        isInstalling = true
        Task { @MainActor in
            await asynchronousInstallation()
            finishInstallation()
        }
    }

    func waitUntilReady() async {
        start()
        guard !isReady else { return }
        await withCheckedContinuation { continuation in
            whenReady { continuation.resume() }
        }
    }

    /// Used only by synchronous Bluetooth restoration and deterministic stages,
    /// before ordinary foreground installation has started.
    func ensureReady() {
        guard !isReady, !isInstalling, let installation else { return }
        isInstalling = true
        installation()
        finishInstallation()
    }

    private func finishInstallation() {
        self.installation = nil
        asynchronousInstallation = nil
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

/// Touch delivery must never wait for service installation. Service-dependent
/// actions use `whenReady` or `waitUntilReady` at their own entry points.
final class AppLaunchWindow: UIWindow {}
