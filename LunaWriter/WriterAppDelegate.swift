import LunaPremium
import UIKit
import UserNotifications
import LunaWriterLibraryUI

@main
final class WriterAppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PremiumAccess.shared.start()
        WriterWiring.install()
        UNUserNotificationCenter.current().delegate = self
        if NSClassFromString("XCTestCase") == nil {
            AutomationEntityIndex.install {
                let stack = try WriterWiring.storageStack()
                try await AutomationEntityIndex.replace(WriterDocumentEntity.self, entities: stack.library.documents(matching: .init(), scope: nil).map(WriterDocumentEntity.init(document:)))
                try await AutomationEntityIndex.replace(WriterNoteEntity.self, entities: stack.library.allNotes().map(WriterNoteEntity.init))
                try await AutomationEntityIndex.replace(WriterGroupEntity.self, entities: stack.library.groups().map(WriterGroupEntity.init))
            }
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix("luna.change.") ? [] : [.banner, .list, .sound])
    }

    func applicationWillTerminate(_ application: UIApplication) {
        WriterWiring.applicationDidEnterBackground()
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role)
        configuration.delegateClass = WriterSceneDelegate.self
        return configuration
    }

    /// Mac ("Designed for iPad") menu bar coverage for the same commands
    /// `LibraryRootViewController.keyCommands` offers on iPad — a Mac app
    /// with no File menu is unusable (organiser #11). The actions are
    /// reached by selector name rather than `#selector`, since the methods
    /// are private to a type in another module; Objective-C dispatch finds
    /// them on whichever responder in the chain implements them regardless.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }

        func command(
            _ title: String, _ selectorName: String, _ input: String, _ modifiers: UIKeyModifierFlags
        ) -> UICommand {
            UIKeyCommand(title: title, action: Selector((selectorName)), input: input, modifierFlags: modifiers)
        }

        builder.insertChild(
            UIMenu(
                options: .displayInline,
                children: [
                    command(WriterCommandTitles.newSheet, "newSheetKeyCommand", "n", .command),
                    command(WriterCommandTitles.newGroup, "newGroupKeyCommand", "n", [.command, .shift]),
                ]),
            atStartOfMenu: .file)

        builder.insertChild(
            UIMenu(
                options: .displayInline,
                children: [
                    command(
                        WriterCommandTitles.trash, "trashOpenDocumentKeyCommand",
                        UIKeyCommand.inputDelete, .command),
                    command(WriterCommandTitles.export, "exportOpenDocumentKeyCommand", "e", .command),
                ]),
            atEndOfMenu: .file)

        builder.insertSibling(
            UIMenu(
                options: .displayInline,
                children: [
                    command(WriterCommandTitles.focusSearch, "focusSearchKeyCommand", "f", .command),
                    command(
                        WriterCommandTitles.toggleNotes, "toggleNotesKeyCommand", "n",
                        [.command, .alternate]),
                ]),
            afterMenu: .find)

        builder.insertChild(
            UIMenu(
                options: .displayInline,
                children: [
                    command(WriterCommandTitles.focusGroups, "focusGroupsKeyCommand", "1", .command),
                    command(WriterCommandTitles.focusSheets, "focusSheetsKeyCommand", "2", .command),
                    command(WriterCommandTitles.focusEditor, "focusEditorKeyCommand", "3", .command),
                ]),
            atStartOfMenu: .view)

        builder.insertChild(
            UIMenu(
                options: .displayInline,
                children: [
                    command(WriterCommandTitles.settings, "openSettingsKeyCommand", ",", .command),
                ]),
            atEndOfMenu: .application)
    }
}
