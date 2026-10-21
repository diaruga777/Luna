import XCTest
import Darwin
import LunaCodeCore
import LunaVaultBEP
import LunaVaultTailscale

final class CodeStreamDemultiplexerTests: XCTestCase {
    private func pair() throws -> (FileDescriptorByteStream, FileDescriptorByteStream) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw BEPStreamError.posix(errno) }
        return (FileDescriptorByteStream(fileDescriptor: descriptors[0]), FileDescriptorByteStream(fileDescriptor: descriptors[1]))
    }
    func testBEPHelloMagicIsReplayedWithoutModification() async throws {
        let pair = try pair(); defer { pair.0.close(); pair.1.close() }
        let hello = BEPHello(deviceName: "fixture", clientName: "Luna", clientVersion: "1")
        try await pair.1.write(BEPFraming.encodeHello(hello))
        let routed = try await LunaCodeStreamDemultiplexer.classify(pair.0)
        XCTAssertFalse(routed.installation)
        let read = try await BEPFraming.readHello(from: routed.stream)
        XCTAssertEqual(read.deviceName, hello.deviceName); XCTAssertEqual(read.clientName, hello.clientName)
    }
    func testDedicatedAppleFrameMagicAndPayloadAreReplayed() async throws {
        let pair = try pair(); defer { pair.0.close(); pair.1.close() }
        let payload = Data("fixture-proof".utf8)
        let bytes = try CodeInstallFrame(.reverseProof, payload: payload).encoded()
        try await pair.1.write(Data(bytes.prefix(2))); try await pair.1.write(Data(bytes.dropFirst(2)))
        let routed = try await LunaCodeStreamDemultiplexer.classify(pair.0)
        XCTAssertTrue(routed.installation)
        let frame = try await CodeInstallFrame.read(from: LunaCodeInstallStream(authenticatedStream: routed.stream))
        XCTAssertEqual(frame.kind, .reverseProof); XCTAssertEqual(frame.payload, payload)
    }
    func testCancellationClosesAStalledClassification() async throws {
        let pair = try pair(); defer { pair.0.close(); pair.1.close() }
        let pending = Task { try await LunaCodeStreamDemultiplexer.classify(pair.0) }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("cancelled classification survived") } catch {}
    }
}
