import Foundation
import LunaVaultBackend

/// Routes Mac endpoint dials by reachability: `.tailscale` endpoints go
/// through the embedded tsnet node, `.lanBonjour` endpoints keep the direct
/// Network-framework path.
public struct VaultTailscaleMacConnector: VaultMacFrameConnecting {
    private let runner: VaultTailnetNodeRunner
    private let lan: any VaultMacFrameConnecting

    public init(runner: VaultTailnetNodeRunner, lan: any VaultMacFrameConnecting) {
        self.runner = runner
        self.lan = lan
    }

    public func connect(to endpoint: VaultMacEndpoint) async throws -> any VaultMacFrameChannel {
        switch endpoint.reachability {
        case .lanBonjour:
            return try await lan.connect(to: endpoint)
        case .tailscale:
            let fd = try await runner.dialTailnet(host: endpoint.host, port: endpoint.port)
            return VaultTailscaleFrameChannel(fileDescriptor: fd)
        }
    }
}
