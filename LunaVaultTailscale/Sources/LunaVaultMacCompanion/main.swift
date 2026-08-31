import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultMac
import LunaVaultTailscale

let arguments = Array(CommandLine.arguments.dropFirst())
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.index(after: index) < arguments.endIndex else { return nil }
    return arguments[arguments.index(after: index)]
}
func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr); exit(2)
}

if arguments.contains("--help") || arguments.isEmpty {
    print("Usage:")
    print("  LunaVaultMacCompanion --initialize --root <directory> --endpoint-binding <binding>")
    print("  LunaVaultMacCompanion --root <directory> [--credential <file>]")
    print("      --tailscale-state <directory> [--tailscale-hostname <name>] [--tailscale-port <port>]")
    print("      [--bind-host <non-wildcard-address>] [--port <port>] [--bonjour-name <name>]")
    print("")
    print("Give at least one transport: --tailscale-state runs an embedded")
    print("Tailscale node (first run opens browser login), --bind-host listens")
    print("directly on a LAN or system-Tailscale address.")
    exit(0)
}

guard let rootPath = value(after: "--root") else { fail("Missing --root. Use --help.") }
let rootURL = URL(fileURLWithPath: rootPath)
let defaultCredentialURL = rootURL.appendingPathComponent("pairing.credential")

func openInBrowser(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try? process.run()
}

do {
    if arguments.contains("--initialize") {
        guard let endpointBinding = value(after: "--endpoint-binding"), !endpointBinding.isEmpty else {
            fail("Missing --endpoint-binding.")
        }
        let random = SystemVaultRandomBytes()
        let credential = try VaultMacPairingCredential(pairingID: UUID(),
            secret: VaultMacPairingSecret(rawValue: random.bytes(count: 32)),
            serverBinding: random.bytes(count: 32), endpointBinding: endpointBinding,
            createdAt: Date())
        try VaultMacPairedCredentialStore().save(credential, at: defaultCredentialURL)
        print("Initialized owner-only pairing credential at \(defaultCredentialURL.path)")
        print("Server fingerprint: \(credential.fingerprint)")
        exit(0)
    }

    let bindHost = value(after: "--bind-host")
    let tailscaleStatePath = value(after: "--tailscale-state")
    guard bindHost != nil || tailscaleStatePath != nil else {
        fail("Give --tailscale-state and/or --bind-host. Use --help.")
    }
    let credentialURL = value(after: "--credential").map(URL.init(fileURLWithPath:)) ?? defaultCredentialURL
    let credential = try VaultMacPairedCredentialStore().load(from: credentialURL)
    guard credential.revokedAt == nil else { fail("Pairing credential is revoked; re-pair before listening.") }
    let store = try VaultMacCompanionStore(rootURL: rootURL, credential: credential)
    let service = VaultMacCompanionService(store: store)
    let authority = VaultMacSessionAuthority(credential: credential)
    let limits = VaultMacListenerLimits()
    // One gate across both transports so the connection and failure budgets
    // hold for the companion as a whole.
    let gate = VaultMacConnectionGate(limits: limits)

#if canImport(Network)
    if let bindHost {
        guard let port = UInt16(value(after: "--port") ?? "49200") else {
            fail("Invalid --port. Use --help.")
        }
        let listener = try VaultMacTCPListener(bindHost: bindHost, port: port,
            advertiseName: value(after: "--bonjour-name"), service: service,
            authority: authority, limits: limits, gate: gate)
        listener.start()
        print("Listening on \(bindHost):\(listener.port) (LAN or system-Tailscale route).")
    }
#else
    if bindHost != nil { fail("Network.framework is unavailable on this platform.") }
#endif

    if let tailscaleStatePath {
        guard let tailscalePort = UInt16(value(after: "--tailscale-port") ?? "49200") else {
            fail("Invalid --tailscale-port. Use --help.")
        }
        let hostName = value(after: "--tailscale-hostname") ?? "luna-vault-mac"
        let runner = VaultTailnetNodeRunner(configuration: VaultTailnetConfiguration(
            stateDirectory: URL(fileURLWithPath: tailscaleStatePath),
            hostName: hostName))
        let server = VaultMacChannelServer(service: service, authority: authority,
                                           limits: limits, gate: gate)
        Task {
            do {
                if await runner.statusSummary()?.backend != .running {
                    print("Connecting the embedded Tailscale node…")
                    for try await event in await runner.interactiveLoginEvents() {
                        switch event {
                        case .browseToURL(let url):
                            print("Finish Tailscale login in your browser: \(url.absoluteString)")
                            openInBrowser(url)
                        case .loginFinished:
                            print("Tailscale login accepted; waiting for the node…")
                        case .running:
                            break
                        }
                    }
                }
                let summary = try await runner.ensureRunningWithExistingLogin()
                let host = summary.dnsName ?? summary.ipv4
                print("Embedded Tailscale node is running as \(host ?? "<unknown>")"
                      + (summary.tailnetName.map { " on tailnet \($0)" } ?? "") + ".")
                if let host {
                    print("Endpoint binding for pairing: tailscale:\(host):\(tailscalePort)")
                }
                let listener = try await runner.tailnetListener(port: tailscalePort)
                print("Listening on the tailnet at port \(tailscalePort).")
                for try await connection in listener.connections() {
                    Task { await server.run(connection.channel, peer: connection.peer) }
                }
                fail("The tailnet listener stopped.")
            } catch {
                fail("Unable to serve over Tailscale: \(error)")
            }
        }
    }

    dispatchMain()
} catch {
    fail("Unable to start companion: \(error)")
}
