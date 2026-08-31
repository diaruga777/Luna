// Luna addition to the vendored TailscaleKit sources.
//
// The upstream wrapper splits dial and accept across OutgoingConnection and
// IncomingConnection, and neither exposes both send and receive on one
// connection. Vault's Mac protocol is request/response over a single stream,
// so this file exposes the underlying connected file descriptor directly.
// tailscale_dial and tailscale_accept both return one half of a socketpair;
// the caller owns the descriptor and reads and writes it with POSIX calls.

import Foundation
import LibTailscale

public enum TailscaleSocket {
    /// Dials `address` ("host:port") on the tailnet and returns the connected
    /// file descriptor. The caller owns the descriptor.
    public static func dial(_ tailscale: TailscaleHandle, address: String,
                            proto: NetProtocol = .tcp) throws -> Int32 {
        var conn: TailscaleConnection = 0
        let res = tailscale_dial(tailscale, proto.rawValue, address, &conn)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        return conn
    }

    /// Listens on `address` (":port" or "ip:port") on the tailnet.
    public static func listen(_ tailscale: TailscaleHandle, address: String,
                              proto: NetProtocol = .tcp) throws -> TailscaleListener {
        var listener: TailscaleListener = 0
        let res = tailscale_listen(tailscale, proto.rawValue, address, &listener)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        return listener
    }

    /// Blocks until a peer connects, then returns the connected file
    /// descriptor and the peer's tailnet address when available. The caller
    /// owns the descriptor. Close the listener with `close(2)` to stop.
    public static func accept(_ tailscale: TailscaleHandle,
                              listener: TailscaleListener) throws -> (fd: Int32, remoteAddress: String?) {
        var conn: TailscaleConnection = 0
        let res = tailscale_accept(listener, &conn)
        guard res == 0 else {
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }
        var remote: String?
        var buffer = [CChar](repeating: 0, count: 64)
        buffer.withUnsafeMutableBufferPointer { pointer in
            if let base = pointer.baseAddress,
               tailscale_getremoteaddr(listener, conn, base, 64) == 0 {
                remote = String(cString: base)
            }
        }
        return (conn, remote)
    }
}
