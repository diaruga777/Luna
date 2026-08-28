import Foundation
import LunaVaultBackend
import LunaVaultModels

/// Install this as the first protocol class on a test URLSession. Every request
/// fails before a socket is opened, making accidental network access observable.
public final class VaultNoEgressURLProtocol: URLProtocol, @unchecked Sendable {
    public override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        client?.urlProtocol(self, didFailWithError: VaultScaffoldError.noEgress(url))
    }

    public override func stopLoading() {}

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VaultNoEgressURLProtocol.self]
        return configuration
    }
}

public struct VaultNoEgressNetworkSessionProvider: VaultBackendNetworkSessionProviding, @unchecked Sendable {
    public let session: URLSession

    public init() {
        session = URLSession(configuration: VaultNoEgressURLProtocol.sessionConfiguration())
    }
}
