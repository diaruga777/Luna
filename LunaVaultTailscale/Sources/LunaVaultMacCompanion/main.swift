import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultMac
import LunaVaultTailscale

// Line-buffer stdout so lifecycle prints survive redirection to a log file.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.index(after: index) < arguments.endIndex else { return nil }
    return arguments[arguments.index(after: index)]
}
func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr); exit(2)
}

/// Reports a bind failure the LAN/system-Tailscale listener could not recover
/// from (for example the configured port is already in use). Without this,
/// the listener stayed silently dead while the companion kept printing
/// "Listening on host:port".
struct TCPListenerFailureReporter: VaultMacListenerFailureObserving {
    func vaultMacListenerFailed(_ error: Error) {
        fail("TCP listener failed: \(error)")
    }
}

if arguments.contains("--help") || arguments.isEmpty {
    print("Usage:")
    print("  LunaVaultMacCompanion --initialize --root <directory> --endpoint-binding <binding>")
    print("  LunaVaultMacCompanion --initialize --root <directory> --tailscale-state <directory>")
    print("      [--tailscale-hostname <name>] [--tailscale-port <port>]")
    print("  LunaVaultMacCompanion --root <directory> [--credential <file>]")
    print("      --tailscale-state <directory> [--tailscale-hostname <name>] [--tailscale-port <port>]")
    print("      [--bind-host <non-wildcard-address>] [--port <port>] [--bonjour-name <name>]")
    print("")
    print("Give at least one transport: --tailscale-state runs an embedded")
    print("Tailscale node (first run opens browser login), --bind-host listens")
    print("directly on a LAN or system-Tailscale address. Initializing with")
    print("--tailscale-state logs the node in first and derives the endpoint")
    print("binding from its MagicDNS name.")
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

func makeRunner(statePath: String) -> VaultTailnetNodeRunner {
    VaultTailnetNodeRunner(configuration: VaultTailnetConfiguration(
        stateDirectory: URL(fileURLWithPath: statePath),
        hostName: value(after: "--tailscale-hostname") ?? "luna-vault-mac"))
}

/// Logs the embedded node in (browser web auth on first run) and returns its
/// running status.
func connectTailnet(_ runner: VaultTailnetNodeRunner) async throws -> VaultTailnetStatusSummary {
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
    return try await runner.ensureRunningWithExistingLogin()
}

do {
    if arguments.contains("--initialize") {
        let writeCredential: (String) throws -> Void = { endpointBinding in
            let random = SystemVaultRandomBytes()
            let credential = try VaultMacPairingCredential(pairingID: UUID(),
                secret: VaultMacPairingSecret(rawValue: random.bytes(count: 32)),
                serverBinding: random.bytes(count: 32), endpointBinding: endpointBinding,
                createdAt: Date())
            try VaultMacPairedCredentialStore().save(credential, at: defaultCredentialURL)
            print("Initialized owner-only pairing credential at \(defaultCredentialURL.path)")
            print("Endpoint binding: \(endpointBinding)")
            print("Server fingerprint: \(credential.fingerprint)")
        }
        if let endpointBinding = value(after: "--endpoint-binding"), !endpointBinding.isEmpty {
            try writeCredential(endpointBinding)
            exit(0)
        }
        guard let statePath = value(after: "--tailscale-state") else {
            fail("Missing --endpoint-binding (or --tailscale-state to derive one).")
        }
        guard let port = UInt16(value(after: "--tailscale-port") ?? "49200") else {
            fail("Invalid --tailscale-port.")
        }
        let runner = makeRunner(statePath: statePath)
        Task {
            do {
                let summary = try await connectTailnet(runner)
                guard let host = summary.dnsName ?? summary.ipv4 else {
                    fail("The node is running but reported no MagicDNS name or address.")
                }
                try writeCredential("tailscale:\(host):\(port)")
                exit(0)
            } catch {
                fail("Unable to initialize over Tailscale: \(error)")
            }
        }
        dispatchMain()
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
            authority: authority, limits: limits, gate: gate,
            failureObserver: TCPListenerFailureReporter())
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
        let runner = makeRunner(statePath: tailscaleStatePath)
        let server = VaultMacChannelServer(service: service, authority: authority,
                                           limits: limits, gate: gate)
        Task {
            do {
                let summary = try await connectTailnet(runner)
                let host = summary.dnsName ?? summary.ipv4
                print("Embedded Tailscale node is running as \(host ?? "<unknown>")"
                      + (summary.tailnetName.map { " on tailnet \($0)" } ?? "") + ".")
                if let host {
                    print("Endpoint binding for pairing: tailscale:\(host):\(tailscalePort)")
                }
                let listener = try await runner.tailnetListener(port: tailscalePort)
                print("Listening on the tailnet at port \(tailscalePort).")
                for try await connection in listener.connections() {
                    print("[\(ISO8601DateFormatter().string(from: Date()))] Tailnet connection from \(connection.peer).")
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
