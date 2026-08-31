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
            VaultTailnetLog.node.info("Connecting to \(endpoint.host, privacy: .public):\(endpoint.port, privacy: .public) over the direct LAN path.")
            return try await lan.connect(to: endpoint)
        case .tailscale:
            VaultTailnetLog.node.info("Connecting to \(endpoint.host, privacy: .public):\(endpoint.port, privacy: .public) through the embedded tailnet.")
            let fd = try await runner.dialTailnet(host: endpoint.host, port: endpoint.port)
            return VaultTailscaleFrameChannel(fileDescriptor: fd)
        }
    }
}
