//
//  ProviderInference.swift
//  LunaMailAccount
//

import Foundation

/// Infers a `MailProvider` from an email address. Known consumer domains map
/// straight to their provider; anything else is `.generic`, whose server
/// settings are resolved by autodiscovery (Thunderbird's ISPDB) or manual entry.
public enum ProviderInference {

    /// The domain part of an address, lowercased (`"a@B.com"` → `"b.com"`).
    public static func domain(of address: String) -> String? {
        guard let at = address.firstIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return domain.isEmpty ? nil : domain
    }

    /// Best-guess provider for an address from its domain alone (synchronous).
    /// Unknown domains return `.generic`.
    public static func inferProviderID(for address: String) -> MailProvider.ID {
        guard let domain = domain(of: address) else { return .generic }
        for provider in MailProvider.ID.allCases where provider != .generic {
            if MailProvider.provider(for: provider).domains.contains(domain) {
                return provider
            }
        }
        return .generic
    }

    // MARK: - Autodiscovery (generic domains)

    /// Server settings discovered for a custom domain.
    public struct DiscoveredConfig: Equatable {
        public var server: MailServerConfig
        public init(server: MailServerConfig) { self.server = server }
    }

    /// Looks up IMAP/SMTP settings for a custom domain via Thunderbird's open
    /// ISPDB (`autoconfig.thunderbird.net`). Returns nil if the domain isn't
    /// listed or the config lacks IMAP+SMTP — the caller then asks for manual
    /// entry. Never throws; a network failure is just a nil result.
    public static func autodiscover(
        domain: String,
        session: URLSession = .shared
    ) async -> DiscoveredConfig? {
        guard let url = URL(string: "https://autoconfig.thunderbird.net/v1.1/\(domain)")
        else { return nil }
        guard let data = try? await session.data(from: url).0 else { return nil }
        return parseISPDB(String(decoding: data, as: UTF8.self))
    }

    /// Parses the ISPDB `clientConfig` XML into a server config, picking the
    /// IMAP incoming server and the SMTP outgoing server. Pure + unit-tested.
    public static func parseISPDB(_ xml: String) -> DiscoveredConfig? {
        guard let imap = firstServer(in: xml, tag: "incomingServer", type: "imap"),
              let smtp = firstServer(in: xml, tag: "outgoingServer", type: "smtp")
        else { return nil }
        let smtpStartTLS = smtp.socketType.uppercased() == "STARTTLS" || smtp.port == 587
        return DiscoveredConfig(server: MailServerConfig(
            imapHost: imap.hostname, imapPort: imap.port,
            smtpHost: smtp.hostname, smtpPort: smtp.port, smtpUsesSTARTTLS: smtpStartTLS))
    }

    private struct ServerElement {
        let hostname: String
        let port: Int
        let socketType: String
    }

    /// Extremely small, dependency-free XML scan: finds the first
    /// `<tag type="type">…</tag>` block and reads its hostname/port/socketType.
    private static func firstServer(in xml: String, tag: String, type: String) -> ServerElement? {
        // Find an opening tag whose attributes include type="<type>".
        var searchStart = xml.startIndex
        while let open = xml.range(of: "<\(tag)", range: searchStart..<xml.endIndex) {
            guard let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex)
            else { return nil }
            let block = String(xml[open.lowerBound..<close.upperBound])
            if block.contains("type=\"\(type)\"") || block.contains("type='\(type)'") {
                guard let host = value(of: "hostname", in: block),
                      let portString = value(of: "port", in: block),
                      let port = Int(portString) else { return nil }
                let socket = value(of: "socketType", in: block) ?? ""
                return ServerElement(hostname: host, port: port, socketType: socket)
            }
            searchStart = close.upperBound
        }
        return nil
    }

    /// Reads the text content of `<name>…</name>` inside `block`.
    private static func value(of name: String, in block: String) -> String? {
        guard let open = block.range(of: "<\(name)>"),
              let close = block.range(of: "</\(name)>", range: open.upperBound..<block.endIndex)
        else { return nil }
        return String(block[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
