import Darwin
import Foundation
import LunaVaultBackend
import LunaVaultTailscale
import TailscaleKit
import XCTest

/// The embedded-Tailscale transport without a tailnet: the frame channel is
/// exercised over a socketpair (the same shape tsnet hands out — a connected
/// stream socket fd), the login reducer over primitive notify fields, and the
/// connector's routing over injected seams. Live tailnet, DERP, and MagicDNS
/// behavior stay on the two-device manual matrix, like the rest of the Mac
/// transport.
final class VaultTailscaleTransportTests: XCTestCase {

    private func makeChannelPair() throws -> (VaultTailscaleFrameChannel, VaultTailscaleFrameChannel) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw VaultMacProtocolError.unavailable
        }
        return (VaultTailscaleFrameChannel(fileDescriptor: fds[0]),
                VaultTailscaleFrameChannel(fileDescriptor: fds[1]))
    }

    private func makeRawPeerPair() throws -> (channel: VaultTailscaleFrameChannel, rawFD: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw VaultMacProtocolError.unavailable
        }
        return (VaultTailscaleFrameChannel(fileDescriptor: fds[0]), fds[1])
    }

    func testFrameRoundtripInBothDirections() async throws {
        let (a, b) = try makeChannelPair()
        defer { a.close(); b.close() }
        let request = Data("stat-request".utf8)
        let response = Data(repeating: 0xAB, count: 300_000)
        try await a.send(request)
        let received = try await b.receive()
        XCTAssertEqual(received, request)
        try await b.send(response)
        let answered = try await a.receive()
        XCTAssertEqual(answered, response)
    }

    func testConsecutiveFramesKeepBoundaries() async throws {
        let (a, b) = try makeChannelPair()
        defer { a.close(); b.close() }
        let frames = [Data("one".utf8), Data(repeating: 7, count: 70_000), Data("three".utf8)]
        for frame in frames { try await a.send(frame) }
        for frame in frames {
            let received = try await b.receive()
            XCTAssertEqual(received, frame)
        }
    }

    /// The tailnet channel must speak exactly the NW channel's wire format:
    /// a 4-byte big-endian length prefix before each frame.
    func testWireFormatIsFourByteBigEndianLengthPrefix() async throws {
        let (channel, rawFD) = try makeRawPeerPair()
        defer { channel.close(); Darwin.close(rawFD) }
        let frame = Data("parity".utf8)
        try await channel.send(frame)
        var raw = [UInt8](repeating: 0, count: 4 + frame.count)
        XCTAssertEqual(Darwin.read(rawFD, &raw, raw.count), raw.count)
        XCTAssertEqual(Array(raw[0..<4]), [0, 0, 0, UInt8(frame.count)])
        XCTAssertEqual(Data(raw[4...]), frame)

        var incoming: [UInt8] = [0, 0, 0, 2] + [0x41, 0x42]
        XCTAssertEqual(Darwin.write(rawFD, &incoming, incoming.count), incoming.count)
        let received = try await channel.receive()
        XCTAssertEqual(received, Data("AB".utf8))
    }

    func testOversizeSendIsRejectedBeforeTouchingTheSocket() async throws {
        let (a, b) = try makeChannelPair()
        defer { a.close(); b.close() }
        let oversize = Data(count: VaultMacProtocol.maximumFrameBytes + 1025)
        do {
            try await a.send(oversize)
            XCTFail("Oversize frame must be rejected")
        } catch { }
    }

    func testAbsurdLengthHeaderIsRejected() async throws {
        let (channel, rawFD) = try makeRawPeerPair()
        defer { channel.close(); Darwin.close(rawFD) }
        var header: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertEqual(Darwin.write(rawFD, &header, 4), 4)
        do {
            _ = try await channel.receive()
            XCTFail("An absurd frame length must be rejected")
        } catch { }
    }

    func testPeerCloseEndsReceive() async throws {
        let (channel, rawFD) = try makeRawPeerPair()
        Darwin.close(rawFD)
        defer { channel.close() }
        do {
            _ = try await channel.receive()
            XCTFail("EOF must surface as an error")
        } catch { }
    }

    func testCloseUnblocksAPendingReceive() async throws {
        let (a, b) = try makeChannelPair()
        defer { b.close() }
        let pending = Task { try await a.receive() }
        try await Task.sleep(nanoseconds: 100_000_000)
        a.close()
        do {
            _ = try await pending.value
            XCTFail("close() must terminate a blocked receive")
        } catch { }
    }

    // MARK: - Login reducer

    func testLoginReducerPrefersErrorsThenCompletionThenBrowse() {
        XCTAssertEqual(VaultTailnetLoginStep.reduce(browseToURL: "https://login.tailscale.com/a/x",
                                                    loginFinished: true, stateRaw: nil,
                                                    errMessage: "boom"),
                       .failed("boom"))
        XCTAssertEqual(VaultTailnetLoginStep.reduce(browseToURL: nil, loginFinished: true,
                                                    stateRaw: nil, errMessage: nil),
                       .finished)
        XCTAssertEqual(VaultTailnetLoginStep.reduce(browseToURL: nil, loginFinished: false,
                                                    stateRaw: Ipn.State.Running.rawValue,
                                                    errMessage: nil),
                       .finished)
        XCTAssertEqual(VaultTailnetLoginStep.reduce(browseToURL: "https://login.tailscale.com/a/x",
                                                    loginFinished: false, stateRaw: nil,
                                                    errMessage: nil),
                       .browse(URL(string: "https://login.tailscale.com/a/x")!))
        XCTAssertEqual(VaultTailnetLoginStep.reduce(browseToURL: nil, loginFinished: false,
                                                    stateRaw: Ipn.State.NeedsLogin.rawValue,
                                                    errMessage: nil),
                       .none)
    }

    func testLoginReducerRejectsNonWebBrowseURLs() {
        XCTAssertEqual(VaultTailnetLoginStep.reduce(browseToURL: "file:///etc/passwd",
                                                    loginFinished: false, stateRaw: nil,
                                                    errMessage: nil),
                       .none)
        XCTAssertEqual(VaultTailnetLoginStep.reduce(browseToURL: "not a url at all \u{7}",
                                                    loginFinished: false, stateRaw: nil,
                                                    errMessage: nil),
                       .none)
    }

    // MARK: - Status mapping

    func testBackendStateMappingCoversIpnStringsAndFailsSoft() {
        XCTAssertEqual(VaultTailnetStatusSummary.Backend(backendState: "Running"), .running)
        XCTAssertEqual(VaultTailnetStatusSummary.Backend(backendState: "NeedsLogin"), .needsLogin)
        XCTAssertEqual(VaultTailnetStatusSummary.Backend(backendState: "NoState"), .noState)
        XCTAssertEqual(VaultTailnetStatusSummary.Backend(backendState: "Stopped"), .stopped)
        XCTAssertEqual(VaultTailnetStatusSummary.Backend(backendState: "Starting"), .starting)
        XCTAssertEqual(VaultTailnetStatusSummary.Backend(backendState: "SomethingNew"), .unknown)
    }

    func testStatusSummaryTrimsDNSDotAndSplitsAddresses() throws {
        let json = Data("""
        {"Version":"1","BackendState":"Running","AuthURL":"",
         "TailscaleIPs":["100.64.1.2","fd7a:115c:a1e0::1"],
         "Self":{"ID":"n1","HostName":"mac","DNSName":"mac.tail1234.ts.net.",
                 "Online":true,"ExitNode":false,"ExitNodeOption":false},
         "CurrentTailnet":{"Name":"example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true}}
        """.utf8)
        let status = try JSONDecoder().decode(IpnState.Status.self, from: json)
        let summary = VaultTailnetNodeRunner.summary(from: status)
        XCTAssertEqual(summary.backend, .running)
        XCTAssertEqual(summary.dnsName, "mac.tail1234.ts.net")
        XCTAssertEqual(summary.tailnetName, "example.com")
        XCTAssertEqual(summary.ipv4, "100.64.1.2")
        XCTAssertEqual(summary.ipv6, "fd7a:115c:a1e0::1")
    }

    // MARK: - Connector routing

    private final class RecordingLanConnector: VaultMacFrameConnecting, @unchecked Sendable {
        let lock = NSLock()
        var endpoints: [VaultMacEndpoint] = []
        func connect(to endpoint: VaultMacEndpoint) async throws -> any VaultMacFrameChannel {
            lock.lock(); endpoints.append(endpoint); lock.unlock()
            var fds: [Int32] = [0, 0]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            Darwin.close(fds[1])
            return VaultTailscaleFrameChannel(fileDescriptor: fds[0])
        }
    }

    private func makeLoginlessRunner() throws -> VaultTailnetNodeRunner {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-tailnet-tests-\(UUID().uuidString)", isDirectory: true)
        return VaultTailnetNodeRunner(configuration: VaultTailnetConfiguration(
            stateDirectory: state, hostName: "luna-vault-test"))
    }

    func testConnectorRoutesBonjourEndpointsToTheLanPath() async throws {
        let lan = RecordingLanConnector()
        let connector = VaultTailscaleMacConnector(runner: try makeLoginlessRunner(), lan: lan)
        let endpoint = try VaultMacEndpoint(host: "studio.local", port: 49_200,
                                            reachability: .lanBonjour)
        let channel = try await connector.connect(to: endpoint)
        channel.close()
        XCTAssertEqual(lan.endpoints, [endpoint])
    }

    /// A tailscale endpoint with no stored login must fail closed without
    /// starting a node or touching the network, so sync reports an honest
    /// unavailable state instead of hanging.
    func testConnectorFailsClosedForTailscaleEndpointsWithoutALogin() async throws {
        let lan = RecordingLanConnector()
        let connector = VaultTailscaleMacConnector(runner: try makeLoginlessRunner(), lan: lan)
        let endpoint = try VaultMacEndpoint(host: "mac.tail1234.ts.net", port: 49_200,
                                            reachability: .tailscale)
        do {
            _ = try await connector.connect(to: endpoint)
            XCTFail("Dialing without a tailnet login must fail")
        } catch let error as VaultTailnetError {
            XCTAssertEqual(error, .needsLogin)
        }
        XCTAssertTrue(lan.endpoints.isEmpty)
    }
}
