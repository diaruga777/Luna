import AppKit
import SwiftUI
import Foundation
import LunaVaultMacPeer

@main @MainActor
final class LunaVaultCompanionApp: NSObject, NSApplicationDelegate {
    // This SwiftPM app has no nib to instantiate and retain its delegate.
    // NSApplicationMain alone leaves a running process with no UI or listener.
    static func main() {
        let app = NSApplication.shared
        let delegate = LunaVaultCompanionApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var controller: CompanionController!
    private let presentation = CompanionPresentation()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        controller = CompanionController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Luna Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 440, height: 460)
        window.contentView = NSHostingView(rootView: CompanionView(
            model: presentation,
            copyCode: { [weak self] in self?.copyCode() },
            chooseFolder: { [weak self] in self?.chooseFolder() },
            revealFolder: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: self.controller.sharedFolderPath))
            },
            forgetConnection: { [weak self] in self?.forgetConnection() },
            openPrivacy: { [weak self] in self?.openPrivacySettings() },
            checkYouTubeAudio: { await CompanionYouTubeAudio.shared.refreshCapability() }
        ))
        let appMenu = NSMenu()
        let appItem = NSMenuItem(); appMenu.addItem(appItem)
        let application = NSMenu(); appItem.submenu = application
        application.addItem(withTitle: "About Luna Mac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Luna Mac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: "Quit Luna Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); appMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(); appMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = appMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = LunaMenuBarIcon.image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Luna Mac"
        statusItem.button?.setAccessibilityLabel("Luna Mac")
        let menu = NSMenu()
        for (title, selector) in [("Open Luna Mac", #selector(showWindow)),
                                   ("Copy Connection Code", #selector(copyCode)),
                                   ("Quit Luna Mac", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        window.center(); showWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let snapshot = CompanionPresentation.Snapshot(
                    code: self.controller.pairingCode,
                    status: self.controller.statusText,
                    paired: self.controller.isPaired,
                    clients: self.controller.clients,
                    folder: self.controller.sharedFolderPath,
                    accessIssue: CompanionFileAccess.shared.statusMessage
                )
                if self.presentation.snapshot != snapshot { self.presentation.snapshot = snapshot }
            }
        }
        controller.start()
        Task { await CompanionYouTubeAudio.shared.refreshCapability() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    @objc private func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func copyCode() {
        guard let code = controller.pairingCode else { return }
        controller.openPairingWindow()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.controller.selectFolder(url)
        }
    }
    @objc private func forgetConnection() {
        let alert = NSAlert()
        alert.messageText = "Forget the Luna connection?"
        alert.informativeText = "All Luna apps and devices will disconnect. Files stay on your Mac."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Forget Connection")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.controller.forgetConnection() }
        }
    }
    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}


// The app icon's moon, curved foreground and lock without glass or color.
private enum LunaMenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let moon = NSBezierPath(ovalIn: NSRect(x: 3, y: 5, width: 13, height: 13))
            moon.windingRule = .evenOdd
            moon.appendOval(in: NSRect(x: 5, y: 12, width: 3, height: 2.5))
            moon.appendOval(in: NSRect(x: 10.5, y: 14.5, width: 2, height: 2))
            moon.fill()

            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 1, y: 7))
            wave.curve(to: NSPoint(x: 17, y: 9),
                       controlPoint1: NSPoint(x: 6, y: 9.5), controlPoint2: NSPoint(x: 13, y: 10))
            wave.line(to: NSPoint(x: 17, y: 2))
            wave.curve(to: NSPoint(x: 15, y: 0.5),
                       controlPoint1: NSPoint(x: 17, y: 1), controlPoint2: NSPoint(x: 16, y: 0.5))
            wave.line(to: NSPoint(x: 3, y: 0.5))
            wave.curve(to: NSPoint(x: 1, y: 2),
                       controlPoint1: NSPoint(x: 2, y: 0.5), controlPoint2: NSPoint(x: 1, y: 1))
            wave.close()
            wave.fill()

            // Knock the small lock out of the foreground for a crisp template.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 6.5, y: 2, width: 5, height: 4),
                         xRadius: 0.7, yRadius: 0.7).fill()
            let shackle = NSBezierPath()
            shackle.move(to: NSPoint(x: 7.5, y: 6))
            shackle.line(to: NSPoint(x: 7.5, y: 7))
            shackle.curve(to: NSPoint(x: 10.5, y: 7),
                          controlPoint1: NSPoint(x: 7.5, y: 9), controlPoint2: NSPoint(x: 10.5, y: 9))
            shackle.line(to: NSPoint(x: 10.5, y: 6))
            shackle.lineWidth = 1.2
            shackle.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Luna Mac"
        return image
    }()
}
