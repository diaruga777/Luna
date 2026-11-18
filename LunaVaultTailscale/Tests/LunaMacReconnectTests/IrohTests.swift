import XCTest
import IrohLib
import LunaVaultBEP
@testable import LunaVaultTailscale

final class IrohTests: XCTestCase {
    func testRestartedListenerKeepsPairedEndpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = VaultIrohTransport(directory: directory, preset: { presetMinimal() })
        let first = try await server.listen(port: 49200)
        try await server.stop()
        await server.waitForListenerToClose()
        let next = try await server.listen(port: 49200)
        XCTAssertEqual(first, next)
        try await server.stop()
        await server.waitForListenerToClose()
    }

    func testDirectTunnelCarriesExistingPinnedTLS() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let macRoot = root.appendingPathComponent("Mac"), phoneRoot = root.appendingPathComponent("Phone")
        let mac = LunaVaultGoTransport(configuration: .init(stateDirectory: macRoot))
        let phone = LunaVaultGoTransport(configuration: .init(stateDirectory: phoneRoot))
        let server = VaultIrohTransport(directory: macRoot, preset: { presetMinimal() })
        let client = VaultIrohTransport(directory: phoneRoot, preset: { presetMinimal() })
        let listener = try await mac.listen(bindAddress: "127.0.0.1:0")
        defer { listener.close() }
        let routes = await listener.announcedAddresses.compactMap(VaultPeerAddress.init(syncthingURL:))
        guard case .tcp(_, let port) = try XCTUnwrap(routes.first),
              case .iroh(let id) = try await server.listen(port: port) else { return XCTFail("Expected listeners") }
        let direct = await server.listeningAddresses()
        XCTAssertFalse(direct.isEmpty)
        let expected = try mac.identity()
        do {
            let wrong = try DeviceID(bytes: Data(repeating: 7, count: 32))
            let stream = try await client.dial(id, tls: phone, expecting: wrong, direct: direct)
            stream.close()
            XCTFail("The BEP certificate pin must survive the tunnel")
        } catch let error as VaultTransportError {
            guard case .identityMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let dialed = try await client.dial(id, tls: phone, expecting: expected, direct: direct)
        defer { dialed.close() }
        let accepted = try await listener.accept()
        defer { accepted.stream.close() }
        XCTAssertEqual(accepted.device, try phone.identity())
        let payload = Data(repeating: 0x91, count: 256_000)
        async let incoming = accepted.stream.read(exactly: payload.count)
        try await dialed.write(payload)
        let received = try await incoming
        XCTAssertEqual(received, payload)
        try await client.stop()
        try await server.stop()
    }
}
