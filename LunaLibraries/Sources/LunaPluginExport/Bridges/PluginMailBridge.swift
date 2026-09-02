//
//  PluginMailBridge.swift
//  LunaPluginExport
//

import Foundation
import JavaScriptCore
import LunaMailAccount
import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaSend

/// Whether an account can send at all. It reads `EmailAccountStore`; a test
/// pins the answer instead of writing the App Group Keychain.
public enum PluginExportMailAccount {
    /// Set only by a test. Production leaves it nil.
    public static var readinessOverride: Bool?

    public static var isReady: Bool {
        readinessOverride ?? EmailAccountStore.shared.isReady
    }

    /// The connected account's own address, which every message is From.
    public static var senderAddress: String? {
        EmailAccountStore.shared.account?.address
    }
}

/// Picks the addresses a plugin's message goes to when the plugin named none.
///
/// The picker is UIKit in LunaSocialUI, which this tier does not link, so
/// central Luna's `KindWiring` hands over a witness. Nil means a message with
/// no recipients is refused rather than silently sent nowhere.
public protocol PluginMailRecipientPicking: AnyObject {
    /// The chosen addresses, or nil when the user cancelled.
    @MainActor
    func pickMailRecipients(subject: String) async -> [String]?
}

/// One message a plugin asked Luna to send.
public struct PluginMailMessage: Equatable {
    public let recipients: [String]
    public let subject: String
    public let text: String?
    public let html: String?
    public let attachments: [PluginMailAttachment]

    public init(
        recipients: [String], subject: String, text: String?, html: String?,
        attachments: [PluginMailAttachment]
    ) {
        self.recipients = recipients
        self.subject = subject
        self.text = text
        self.html = html
        self.attachments = attachments
    }
}

public struct PluginMailAttachment: Equatable {
    public let name: String
    public let mime: String
    public let data: Data

    public init(name: String, mime: String, data: Data) {
        self.name = name
        self.mime = mime
        self.data = data
    }
}

/// `luna.mail` (`claudedocs/plans/plugin-platform.md` §6.13): a plugin hands
/// over a message; Luna builds the MIME and sends it through the connected
/// account.
///
/// A plugin never supplies raw headers, and never learns the account's
/// credentials. The transport comes from `ArticleEmailTransportProvider`, which
/// only the app installs, so a send from an extension answers
/// `unavailable-here` rather than failing halfway.
public final class PluginMailBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.mail

    /// The largest total attachment payload one message may carry. Providers
    /// refuse more, and a refusal after the upload is a wasted transfer.
    public static let maxAttachmentBytes = 25 * 1024 * 1024

    private let processKind: PluginProcessKind
    private let scheduler: PluginCallbackScheduling
    private let scratch: PluginScratchStore?
    private let recipientPicker: (any PluginMailRecipientPicking)?
    private let sender: any PluginMailSending

    public init(
        processKind: PluginProcessKind,
        scheduler: PluginCallbackScheduling,
        scratch: PluginScratchStore? = nil,
        recipientPicker: (any PluginMailRecipientPicking)? = nil,
        sender: (any PluginMailSending)? = nil
    ) {
        self.processKind = processKind
        self.scheduler = scheduler
        self.scratch = scratch
        self.recipientPicker = recipientPicker
        self.sender = sender ?? AccountPluginMailSender()
    }

    private var activeScratch: PluginScratchStore? {
        scratch ?? PluginPlatformServices.scratch
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let bridge = self
        let mail = namespace.makeNamespaceObject()

        let send: @convention(block) (JSValue?) -> JSValue? = { message in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            guard bridge.processKind == .app else {
                box.fail("luna.mail.send needs the app", code: "unavailable-here")
                return promise
            }
            let object = PluginBridgeValue.dictionary(message)
            guard let subject = PluginBridgeValue.string(object, "subject") else {
                box.fail("luna.mail.send needs a subject", code: "bad-argument")
                return promise
            }
            let recipients = (object["to"] as? [Any])?.compactMap { $0 as? String } ?? []
            let text = PluginBridgeValue.string(object, "text")
            let html = PluginBridgeValue.string(object, "html")
            let attachments: [PluginMailAttachment]
            do {
                attachments = try bridge.attachments(from: object)
            } catch let failure as PluginMailFailure {
                box.fail(failure.message, code: failure.code)
                return promise
            } catch {
                box.fail("\(error)", code: "bridge-failed")
                return promise
            }
            Task {
                let resolved: [String]
                if recipients.isEmpty {
                    guard let picker = bridge.recipientPicker else {
                        box.fail(
                            "luna.mail.send has no recipient picker here",
                            code: "unavailable-here")
                        return
                    }
                    guard let picked = await picker.pickMailRecipients(subject: subject),
                          !picked.isEmpty
                    else {
                        box.fail("the recipient picker was cancelled", code: "cancelled")
                        return
                    }
                    resolved = picked
                } else {
                    resolved = recipients
                }
                do {
                    try await bridge.sender.sendPluginMail(PluginMailMessage(
                        recipients: resolved, subject: subject, text: text, html: html,
                        attachments: attachments))
                    box.fulfill(["status": "sent"])
                } catch let failure as PluginMailFailure {
                    box.fail(failure.message, code: failure.code)
                } catch {
                    box.fail("\(error)", code: "send-failed")
                }
            }
            return promise
        }

        let isConfigured: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            box.fulfill(bridge.processKind == .app && PluginExportMailAccount.isReady)
            return promise
        }

        mail.setObject(send, forKeyedSubscript: "send" as NSString)
        mail.setObject(isConfigured, forKeyedSubscript: "isConfigured" as NSString)
        namespace.install(mail, as: capabilityName.rawValue)
    }

    /// Reads the attachment list: each entry names a file the plugin holds a
    /// handle to, so its bytes come off disk rather than through JavaScript.
    func attachments(from object: [String: Any]) throws -> [PluginMailAttachment] {
        guard let list = object["attachments"] as? [Any], !list.isEmpty else { return [] }
        guard let scratch = activeScratch else {
            throw PluginMailFailure(
                code: "unavailable-here", message: "no plugin file store is open here")
        }
        var attachments: [PluginMailAttachment] = []
        var total = 0
        for entry in list {
            guard let part = entry as? [String: Any],
                  let handle = part["file"] as? [String: Any],
                  let id = PluginBridgeValue.string(handle, "id")
            else {
                throw PluginMailFailure(
                    code: "bad-argument", message: "an attachment needs a file handle")
            }
            let descriptor = PluginFileDescriptor(
                id: id, name: PluginBridgeValue.string(handle, "name") ?? "file",
                size: PluginBridgeValue.int(handle, "size") ?? 0,
                mime: PluginBridgeValue.string(handle, "mime"))
            guard let url = scratch.fileURL(for: descriptor),
                  let data = try? Data(contentsOf: url)
            else {
                throw PluginMailFailure(
                    code: "not-found", message: "that attachment file is gone")
            }
            total += data.count
            guard total <= Self.maxAttachmentBytes else {
                throw PluginMailFailure(
                    code: "too-large",
                    message: "one message may attach at most "
                        + "\(Self.maxAttachmentBytes / (1024 * 1024)) MB")
            }
            attachments.append(PluginMailAttachment(
                name: PluginBridgeValue.string(part, "name") ?? descriptor.name,
                mime: PluginBridgeValue.string(part, "mime") ?? descriptor.mime
                    ?? "application/octet-stream",
                data: data))
        }
        return attachments
    }
}

/// A refusal a plugin can branch on: the `code` reaches JavaScript as
/// `error.code`.
public struct PluginMailFailure: Error, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Sends one plugin message. The shipped conformer builds the MIME and hands
/// it to the connected account's transport; a test records the message.
public protocol PluginMailSending: AnyObject {
    func sendPluginMail(_ message: PluginMailMessage) async throws
}

/// The connected account's transport, reached the same way every other Luna
/// send reaches it.
public final class AccountPluginMailSender: PluginMailSending {

    public init() {}

    public func sendPluginMail(_ message: PluginMailMessage) async throws {
        guard let from = PluginExportMailAccount.senderAddress else {
            throw PluginMailFailure(
                code: "not-configured", message: "no email account is connected")
        }
        guard let transport = ArticleEmailTransportProvider.installed?.makeTransport() else {
            throw PluginMailFailure(
                code: "unavailable-here", message: "email cannot be sent from this process")
        }
        let mime = PluginMailMIME.build(message, from: from)
        try await transport.send(OutgoingEmail(
            recipients: message.recipients, subject: message.subject, rawMIME: mime))
    }
}
