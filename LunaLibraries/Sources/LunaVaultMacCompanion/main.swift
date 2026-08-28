import Foundation
import LunaVaultBackend
import LunaVaultMac

/// A deliberately small companion entry point. Pairing UI, login/launch-agent
/// integration, and Bonjour publication belong to the macOS app shell; this
/// executable makes the storage/transport foundation runnable in development
/// and in headless integration tests without embedding a Tailscale client.
@main
struct LunaVaultMacCompanionMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.isEmpty {
            print("Usage: LunaVaultMacCompanion --root <directory> --secret-base64 <32-byte-secret> --session <uuid> [--port <port>]")
            return
        }

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
            return arguments[arguments.index(after: index)]
        }

        guard let root = value(after: "--root"),
              let encodedSecret = value(after: "--secret-base64"),
              let sessionString = value(after: "--session"),
              let sessionID = UUID(uuidString: sessionString),
              let secret = try? VaultMacPairingSecret(base64Encoded: encodedSecret),
              let port = UInt16(value(after: "--port") ?? "49200") else {
            fputs("Invalid companion arguments. Use --help.\n", stderr)
            return
        }

        do {
            let credentialsURL = URL(fileURLWithPath: root).appendingPathComponent("pairing.credential")
            try VaultMacPairedCredentialStore().save(secret, at: credentialsURL)
            let store = try VaultMacCompanionStore(rootURL: URL(fileURLWithPath: root), secret: secret)
            let service = VaultMacCompanionService(store: store)
#if canImport(Network)
            let listener = try VaultMacTCPListener(port: port, service: service, secret: secret, sessionID: sessionID)
            listener.start()
            print("Luna Vault Mac companion listening on port \(listener.port). Tailscale/LAN are reachability only.")
            dispatchMain()
#else
            _ = service
            print("Luna Vault Mac companion storage is ready; Network.framework is unavailable on this platform.")
#endif
        } catch {
            fputs("Unable to start companion: \(error)\n", stderr)
        }
    }
}
