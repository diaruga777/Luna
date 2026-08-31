// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause
// Luna vendoring change: the C symbols come from the LibTailscale binary
// module instead of a framework bridging header.

import Foundation
import LibTailscale

public let kDefaultControlURL = "https://controlplane.tailscale.com"

/// Handle types the upstream package declares in OutgoingConnection.swift,
/// which Luna does not vendor. See TailscaleSocket for Luna's fd-level dial,
/// listen, and accept.
public typealias TailscaleHandle = Int32
public typealias TailscaleConnection = Int32
public typealias TailscaleListener = Int32

/// The layer 3 protocol to use
public enum NetProtocol: String, Sendable {
    case tcp = "tcp"
    case udp = "udp"
}


/// Configuration for a tailscale application node
public struct Configuration: Sendable {
    public let hostName: String    ///< The hostname of the node/application instance
    public let path: String
    public let authKey: String?    ///< An auth key.  Leave empty to use web auth
    public let controlURL: String  ///< URL for Tailscale control
    public let ephemeral: Bool

    public init(hostName: String,
                path: String,
                authKey: String?,
                controlURL: String,
                ephemeral: Bool = false)
    {
        self.hostName = hostName
        self.path = path
        self.authKey = authKey
        self.controlURL = controlURL
        self.ephemeral = ephemeral
    }

}

public typealias IPAddresses = (ip4: String?, ip6: String?)

// Luna vendoring change: single-flight guard so tailscale_close runs exactly
// once even when interrupt(), an explicit close(), and deinit all race for
// the same handle.
private final class TailscaleNodeCloseGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    /// Calls `tailscale_close` and returns its result the first time this
    /// is reached for a handle; every later call is a no-op that returns
    /// nil.
    @discardableResult
    func closeOnce(_ tailscale: TailscaleHandle) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        return tailscale_close(tailscale)
    }
}

/// TSInterface creates and manages a single userspace Tailscale application
/// node.  You may instantiate several "nodes" in a single application.  Each
/// will get a unique IP address on the Tailnet.
///
/// The provided wrapper abstract away the C code and allow the writing of proper,
/// compiler checked thread-safe Swift 6.
public actor TailscaleNode {

    /// Handle to the underlying Tailscale server.  Use this when instantiating
    /// new IncomingConnections or OutgoingConnections
    //
    // Luna vendoring change: nonisolated. Immutable and Sendable, and
    // VaultTailnetNodeRunner reads it off-actor to dial and to interrupt a
    // wedged tailscale_up (see close()/interrupt() below).
    public nonisolated let tailscale: TailscaleHandle?

    private let logger: LogSink?

    /// Instantiate a new TailscaleNode with the given configuration and
    /// and optional LogSink.  If no LogSink is provided, logs will be
    /// discarded.
    ///
    /// @See tailscale_set_* in Tailscale.h
    /// @See tailscale_start in Tailscale.h
    ///
    /// @throws TailscaleError on failure
    public init(config: Configuration, logger: LogSink?) throws {
        self.logger = logger ?? BlackholeLogger()

        tailscale = tailscale_new()

        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        
        logger?.log("Tailscale starting: \(tailscale)")

        if let fd = logger?.logFileHandle {
            tailscale_set_logfd(tailscale, fd)
        }

        if let authKey = config.authKey {
            tailscale_set_authkey(tailscale, authKey)
        }

        tailscale_set_hostname(tailscale, config.hostName)
        tailscale_set_dir(tailscale, config.path)
        tailscale_set_control_url(tailscale, config.controlURL)
        tailscale_set_ephemeral(tailscale, config.ephemeral ? 1 : 0)

        let res = tailscale_start(tailscale)

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }

        logger?.log("Tailscale started... \(tailscale)")
    }

    // Luna vendoring change: a lock-guarded single-flight so tailscale_close
    // fires exactly once no matter which of interrupt(), close(), and
    // deinit reaches the handle first.
    private let closeGuard = TailscaleNodeCloseGuard()

    deinit {
        if let tailscale {
            closeGuard.closeOnce(tailscale)
        }
    }

    /// Closes/stops the Tailscale server
    ///
    /// @See tailscale_close in Tailscale.h
    ///
    /// @Throws TailscaleError on failure
    //
    // Luna vendoring change: nonisolated and no longer async. up(), close(),
    // and statusJSON() used to isolate to this actor, so a timeout's close()
    // queued behind up()'s still-blocked C call instead of interrupting it.
    // They touch only the immutable handle and logger, so nonisolated is
    // sound, and callers now run them off the actor via a blocking queue
    // (see VaultTailnetNodeRunner.runBlocking).
    public nonisolated func close() throws {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        logger?.log("Closing Tailscale: \(tailscale)")
        guard let res = closeGuard.closeOnce(tailscale) else {
            // Already closed by interrupt() or a prior close(); idempotent.
            return
        }

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        logger?.log("Closed Tailscale:\(tailscale)")
    }

    /// Cross-thread interrupt for a `tailscale_up` call blocked on another
    /// thread: `tailscale_close` is the documented way to unblock it. Safe
    /// to call concurrently with an in-flight `up()` because it never
    /// touches actor-isolated state.
    //
    // Luna vendoring change: added so a bring-up timeout can unwedge a
    // blocked tailscale_up without going through actor isolation.
    public nonisolated func interrupt() {
        guard let tailscale else { return }
        _ = closeGuard.closeOnce(tailscale)
    }

    /// Brings up the Tailscale server
    ///
    /// @See tailscale_up in Tailscale.h
    ///
    /// @throws TailscaleError on failure
    public nonisolated func up() throws {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        logger?.log("Bringing Tailscale up :\(tailscale)")
        let res = tailscale_up(tailscale)

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        logger?.log("Brought Tailscale up:\(tailscale)")
    }

    /// Returns the backend status as the JSON encoding of ipnstate.Status —
    /// the same document LocalAPI's /localapi/v0/status serves.
    ///
    /// Unlike reading /status via loopback()'s HTTP server, this goes through
    /// tsnet's in-memory LocalAPI listener: it keeps working when the OS
    /// reclaims the loopback TCP listener from a suspended process (observed
    /// on iOS), where the cached loopback address goes permanently stale.
    ///
    /// @See tailscale_status_json in Tailscale.h
    ///
    /// @throws TailscaleError on failure
    public nonisolated func statusJSON() throws -> Data {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        var out: UnsafeMutablePointer<CChar>?
        let res = tailscale_status_json(tailscale, &out)

        guard res == 0, let out else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        defer { free(out) }
        return Data(bytes: out, count: strlen(out))
    }

    /// Tears down the Tailscale server.
    ///
    /// @See tailscale_down in Tailscale.h
    ///
    /// @throws TailscaleError on failure
    public func down() throws {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        logger?.log("Taking Tailscale down :\(tailscale)")

        let res = tailscale_up(tailscale)

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        logger?.log("Took Tailscale down:\(tailscale)")
    }

    /// Returns the addresses on the Tailscale server
    ///
    /// @See tailscale_getips in Tailscale.h
    ///
    /// @returns An ipV4 and ipV5 address tuple
    /// @throws TailscaleError on failure
    public func addrs() async throws -> IPAddresses {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: 128)
        defer {
            buf.deallocate()
        }
        let res = tailscale_getips(tailscale, buf, 128)

        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }

        let ipList = String(cString: buf)
        return ipList.toIPPair()
    }

    public struct LoopbackConfig: Sendable {
        public let address: String
        public let proxyCredential: String
        public let localAPIKey: String

        public var ip: String? {
            let parts = address.split(separator: ":")
            let addr = parts.first
            guard parts.count == 2, let addr else {
                return nil
            }
            return String(addr)
        }

        public var port: Int? {
            let parts = address.split(separator: ":")
            let port = parts.last
            guard parts.count == 2, let port else {
                return nil
            }
            return Int(port)
        }
    }

    private var loopbackConfig: LoopbackConfig?

    /// Starts and returns the address and credentials of a SOCKS5 proxy which can also
    /// be used to query the localAPI
    public func loopback() throws -> LoopbackConfig {
        guard let tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        if let loopbackConfig = loopbackConfig {
            return loopbackConfig
        }

        let addrBuf = UnsafeMutablePointer<Int8>.allocate(capacity: 64)
        let proxyCredBuf = UnsafeMutablePointer<Int8>.allocate(capacity: 33)
        let apiCredBuf = UnsafeMutablePointer<Int8>.allocate(capacity: 33)
        defer {
            addrBuf.deallocate()
            proxyCredBuf.deallocate()
            apiCredBuf.deallocate()
        }

        let res = tailscale_loopback(tailscale, addrBuf, 64, proxyCredBuf, apiCredBuf)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }

        loopbackConfig = LoopbackConfig(address: String(cString: addrBuf),
                                        proxyCredential: String(cString: proxyCredBuf),
                                        localAPIKey: String(cString: apiCredBuf))
        return loopbackConfig!

    }
}

// MARK: - IP String list to IPAddresses tuple

enum IPAddrType {
    case v4
    case v6
    case none
}

extension String {
    // tailscale.go sends us the tailnetIPs as a comma separated list.  This will
    // turn them into an IPAddresses tuple
    func toIPPair() -> IPAddresses {
        let ips = self.split(separator: ",").map { String($0) }
        var result: IPAddresses = (nil, nil)
        for ip in ips {
            let type = ip.tsNetIPAddrType()
            switch type {
            case .v4:
                result.ip4 = ip
            case .v6:
                result.ip6 = ip
            case .none:
                break
            }
        }
        return result
    }


    // This can be naive since the backend is only vending well
    // formed IPs to us.
    func tsNetIPAddrType() -> IPAddrType {
        if self.contains(".") {
            return .v4
        } else if self.contains(":") {
            return .v6
        }
        return .none
    }
}


