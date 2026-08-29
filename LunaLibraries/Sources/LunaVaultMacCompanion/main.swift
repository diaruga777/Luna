import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultMac

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
    print("  LunaVaultMacCompanion --root <directory> --credential <file> --bind-host <non-wildcard-address> [--port <port>] [--bonjour-name <name>]")
    exit(0)
}

guard let rootPath = value(after: "--root") else { fail("Missing --root. Use --help.") }
let rootURL = URL(fileURLWithPath: rootPath)
let defaultCredentialURL = rootURL.appendingPathComponent("pairing.credential")

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

    guard let bindHost = value(after: "--bind-host"),
          let port = UInt16(value(after: "--port") ?? "49200") else {
        fail("Missing or invalid --bind-host/--port. Use --help.")
    }
    let credentialURL = value(after: "--credential").map(URL.init(fileURLWithPath:)) ?? defaultCredentialURL
    let credential = try VaultMacPairedCredentialStore().load(from: credentialURL)
    guard credential.revokedAt == nil else { fail("Pairing credential is revoked; re-pair before listening.") }
    let store = try VaultMacCompanionStore(rootURL: rootURL, credential: credential)
    let service = VaultMacCompanionService(store: store)
#if canImport(Network)
    let authority = VaultMacSessionAuthority(credential: credential)
    let listener = try VaultMacTCPListener(bindHost: bindHost, port: port,
        advertiseName: value(after: "--bonjour-name"), service: service, authority: authority)
    listener.start()
    print("Luna Vault Mac companion listening on \(bindHost):\(listener.port). The configured LAN/Tailscale transport determines the route.")
    dispatchMain()
#else
    _ = service
    fail("Network.framework is unavailable on this platform.")
#endif
} catch {
    fail("Unable to start companion: \(error)")
}
