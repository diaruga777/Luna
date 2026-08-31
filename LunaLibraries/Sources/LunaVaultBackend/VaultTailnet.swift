import Foundation

/// Snapshot of the embedded tailnet node for status UI and dial gating.
/// `backend` mirrors ipn's BackendState strings; an unrecognized raw value
/// maps to `.unknown` rather than failing, matching the store's enum policy.
public struct VaultTailnetStatusSummary: Equatable, Sendable {
    public enum Backend: Equatable, Sendable {
        case noState, needsLogin, needsMachineAuth, stopped, starting, running, unknown

        public init(backendState: String) {
            switch backendState {
            case "NoState": self = .noState
            case "NeedsLogin": self = .needsLogin
            case "NeedsMachineAuth": self = .needsMachineAuth
            case "Stopped": self = .stopped
            case "Starting": self = .starting
            case "Running": self = .running
            default: self = .unknown
            }
        }
    }

    public let backend: Backend
    public let dnsName: String?
    public let tailnetName: String?
    public let ipv4: String?
    public let ipv6: String?

    public init(backend: Backend, dnsName: String? = nil, tailnetName: String? = nil,
                ipv4: String? = nil, ipv6: String? = nil) {
        self.backend = backend
        self.dnsName = dnsName.flatMap { $0.isEmpty ? nil : $0 }
        self.tailnetName = tailnetName.flatMap { $0.isEmpty ? nil : $0 }
        self.ipv4 = ipv4.flatMap { $0.isEmpty ? nil : $0 }
        self.ipv6 = ipv6.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum VaultTailnetAuthEvent: Equatable, Sendable {
    /// The control plane wants the user to finish login in a browser.
    case browseToURL(URL)
    /// The control plane accepted the login; the node is coming up.
    case loginFinished
    /// The node is usable. Terminal event of a successful login stream.
    case running(VaultTailnetStatusSummary)
}

/// Installed by the app so Vault settings can drive the embedded tailnet
/// without linking the Tailscale package. The login stream finishes after
/// `.running`, or throws when the control plane reports an error.
public protocol VaultTailnetControlling: Sendable {
    /// Nil when no embedded node state exists yet and none is running.
    func statusSummary() async -> VaultTailnetStatusSummary?
    func interactiveLoginEvents() async -> AsyncThrowingStream<VaultTailnetAuthEvent, Error>
    func logout() async throws
}
