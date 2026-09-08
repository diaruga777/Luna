import Darwin
import Foundation
import LunaVaultBackend
import LunaVaultTailscale
import TailscaleKit
import XCTest

/// Regression coverage for the Vault review's LunaVaultTailscale findings
/// (VAULT_REVIEW_PLAN.md, "Cluster: LunaVaultTailscale + vendored
/// TailscaleKit"). Only the findings that are cheap to pin without a live
/// tailnet are covered here; the bring-up timeout/interrupt threading fix
/// needs a real blocked `tailscale_up` and stays on the two-device manual
/// matrix like the rest of the live-tailnet behavior, per
/// VaultTailscaleTransportTests's own stated boundary.
final class VaultTailnetReviewFixTests: XCTestCase {

    // MARK: - SO_NOSIGPIPE (finding: no SIGPIPE guard on the frame channel)

    /// Before the fix, a write to a socket whose peer already closed raised
    /// SIGPIPE and killed the process; nothing in `send()` could catch
    /// that. `VaultTailscaleFrameChannel.init` now sets SO_NOSIGPIPE while
    /// the pair is still connected (setsockopt fails once the peer is
    /// already gone, so the fix has to run at construction time, before
    /// close — this test's ordering mirrors that), so the same write now
    /// surfaces EPIPE through `send()`'s existing errno path instead.
    func testSendAfterPeerCloseThrowsInsteadOfCrashing() async throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw VaultMacProtocolError.unavailable
        }
        // Wrap fds[0] while fds[1] is still connected, matching how a real
        // dial or accept hands the channel a freshly connected descriptor.
        let channel = VaultTailscaleFrameChannel(fileDescriptor: fds[0])
        defer { channel.close() }
        // Now simulate the peer disconnecting mid-sync.
        Darwin.close(fds[1])
        do {
            try await channel.send(Data("after-peer-close".utf8))
            XCTFail("A send after the peer closes must throw, not crash the process")
        } catch { }
    }

    /// Same guard on the accept-side construction path (VaultTailnetListener
    /// wraps an accepted fd through the same init as the dial path).
    func testSendAfterPeerCloseOnAnAcceptedFileDescriptorThrows() async throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw VaultMacProtocolError.unavailable
        }
        let accepted = VaultTailscaleFrameChannel(fileDescriptor: fds[1])
        defer { accepted.close() }
        Darwin.close(fds[0])
        do {
            try await accepted.send(Data("after-dial-side-close".utf8))
            XCTFail("A send after the peer closes must throw, not crash the process")
        } catch { }
    }

    // MARK: - Login-completed latch (finding: hasPersistedState means "state

    // dir non-empty", not "has a stored login")

    /// A state directory that tsnet wrote to during a login the user then
    /// cancelled is non-empty, but Luna's own login-completed marker was
    /// never written. Dialing must still fail closed on `.needsLogin`
    /// without paying for starting the embedded node — this test's time
    /// bound is the behavioral proxy for "no node was started", since a
    /// real bring-up would take seconds and touch the network.
    func testDialFailsClosedForAnAbandonedLoginWithoutStartingANode() async throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-tailnet-review-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        // tsnet writes machine-key state as soon as a node ever starts,
        // including an abandoned login attempt — simulate that without
        // starting a real node.
        FileManager.default.createFile(
            atPath: state.appendingPathComponent("tailscaled.state").path,
            contents: Data("abandoned-login".utf8))

        let runner = VaultTailnetNodeRunner(configuration: VaultTailnetConfiguration(
            stateDirectory: state, hostName: "luna-vault-review-fix-test"))
        let started = Date()
        do {
            _ = try await runner.dialTailnet(host: "mac.tail1234.ts.net", port: 49_200)
            XCTFail("Dialing with an abandoned login must fail")
        } catch let error as VaultTailnetError {
            XCTAssertEqual(error, .needsLogin)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0,
                          "failing on the login-completed marker must not start the embedded node")
    }

    // MARK: - Listener accept-failure backoff (finding: one tailscale_accept

    // failure used to end the connections stream)

    func testAcceptRetryBackoffGrowsExponentiallyAndCaps() {
        XCTAssertEqual(VaultTailnetListener.acceptRetryBackoff(afterFailureCount: 0), 0)
        XCTAssertEqual(VaultTailnetListener.acceptRetryBackoff(afterFailureCount: 1), 1)
        XCTAssertEqual(VaultTailnetListener.acceptRetryBackoff(afterFailureCount: 2), 2)
        XCTAssertEqual(VaultTailnetListener.acceptRetryBackoff(afterFailureCount: 3), 4)
        XCTAssertEqual(VaultTailnetListener.acceptRetryBackoff(afterFailureCount: 4), 8)
        // Capped rather than unbounded, so a persistently broken listener
        // still retries instead of backing off forever.
        XCTAssertEqual(VaultTailnetListener.acceptRetryBackoff(afterFailureCount: 20), 30)
    }
}
