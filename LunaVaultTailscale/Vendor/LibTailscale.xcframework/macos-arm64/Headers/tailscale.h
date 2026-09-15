// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//
// Tailscale C library.
//
// Use this library to compile Tailscale into your program and get
// an entirely userspace IP address on a tailnet.
//
// From here you can listen for other programs on your tailnet dialing
// you, or connect directly to other services.
//


#include <stddef.h>

#ifndef TAILSCALE_H
#define TAILSCALE_H

#ifdef __cplusplus
extern "C" {
#endif


// tailscale is a handle onto a Tailscale server.
typedef int tailscale;

// tailscale_new creates a tailscale server object.
//
// No network connection is initialized until tailscale_start is called.
extern tailscale tailscale_new();

// tailscale_start connects the server to the tailnet.
//
// Calling this function is optional as it will be called by the first use
// of tailscale_listen or tailscale_dial on a server.
//
// See also: tailscale_up.
//
// Returns zero on success or -1 on error, call tailscale_errmsg for details.
extern int tailscale_start(tailscale sd);

// tailscale_up connects the server to the tailnet and waits for it to be usable.
//
// To cancel an in-progress call to tailscale_up, use tailscale_close.
//
// Returns zero on success or -1 on error, call tailscale_errmsg for details.
extern int tailscale_up(tailscale sd);

// tailscale_close shuts down the server.
//
// Returns:
// 	0     - success
// 	EBADF - sd is not a valid tailscale
// 	-1    - other error, details printed to the tsnet logger
extern int tailscale_close(tailscale sd);

// The following set tailscale configuration options.
//
// Configure these options before any explicit or implicit call to tailscale_start.
//
// For details of each value see the godoc for the fields of tsnet.Server.
//
// Returns zero on success or -1 on error, call tailscale_errmsg for details.
extern int tailscale_set_dir(tailscale sd, const char* dir);
extern int tailscale_set_hostname(tailscale sd, const char* hostname);
extern int tailscale_set_authkey(tailscale sd, const char* authkey);
extern int tailscale_set_control_url(tailscale sd, const char* control_url);
extern int tailscale_set_ephemeral(tailscale sd, int ephemeral);

// tailscale_set_logfd instructs the tailscale instance to write logs to fd.
//
// An fd value of -1 means discard all logging.
//
// Returns zero on success or -1 on error, call tailscale_errmsg for details.
extern int tailscale_set_logfd(tailscale sd, int fd);

// A tailscale_conn is a connection to an address on the tailnet.
//
// It is a pipe(2) on which you can use read(2), write(2), and close(2).
// For extra control over the connection, see the tailscale_conn_* functions.
typedef int tailscale_conn;

// Returns the IP addresses of the the Tailscale server as
// a comma separated list.
//
// The provided buffer must be of sufficient size to hold the concatenated
// IPs as strings.  This is typically <ipv4>,<ipv6> but maybe empty, or
// contain any number of ips.   The caller is responsible for parsing
// the output.  You may assume the output is a list of well-formed IPs.
//
// Returns:
//  0      - Success
// 	EBADF  - sd is not a valid tailscale, or l or conn are not valid listeneras or connections
// 	ERANGE - insufficient storage for buf
extern int tailscale_getips(tailscale sd, char* buf, size_t buflen);

// tailscale_dial connects to the address on the tailnet.
//
// The newly allocated connection is written to conn_out.
//
// network is a NUL-terminated string of the form "tcp", "udp", etc.
// addr is a NUL-terminated string of an IP address or domain name.
//
// It will start the server if it has not been started yet.
//
// Returns zero on success or -1 on error, call tailscale_errmsg for details.
extern int tailscale_dial(tailscale sd, const char* network, const char* addr, tailscale_conn* conn_out);

// A tailscale_listener is a socket on the tailnet listening for connections.
//
// It is much like allocating a system socket(2) and calling listen(2).
// Accept connections with tailscale_accept and close the listener  with close.
//
// Under the hood, a tailscale_listener is one half of a socketpair itself,
// used to move the connection fd from Go to C. This means you can use epoll
// or its equivalent on a tailscale_listener to know if there is a connection
// read to accept.
typedef int tailscale_listener;

// tailscale_listen listens for a connection on the tailnet.
//
// It is the spiritual equivalent to listen(2).
// The newly allocated listener is written to listener_out.
//
// network is a NUL-terminated string of the form "tcp", "udp", etc.
// addr is a NUL-terminated string of an IP address or domain name.
//
// It will start the server if it has not been started yet.
//
// Returns zero on success or -1 on error, call tailscale_errmsg for details.
extern int tailscale_listen(tailscale sd, const char* network, const char* addr, tailscale_listener* listener_out);

// Returns the remote address for an incoming connection for a particular listener.  The address (eitehr ip4 or ip6)
// will ge written to buf on on success.
// Returns:
//   0    - Success
// 	EBADF  - sd is not a valid tailscale, or l or conn are not valid listeneras or connections
// 	ERANGE - insufficient storage for buf
extern int tailscale_getremoteaddr(tailscale_listener l, tailscale_conn conn, char* buf, size_t buflen);


// tailscale_accept accepts a connection on a tailscale_listener.
//
// It is the spiritual equivalent to accept(2).
//
// The newly allocated connection is written to conn_out.
//
// Returns:
// 	0     - success
// 	EBADF - listener is not a valid tailscale
// 	-1    - call tailscale_errmsg for details
extern int tailscale_accept(tailscale_listener listener, tailscale_conn* conn_out);

// tailscale_loopback starts a loopback address server.
//
// The server has multiple functions.
//
// It can be used as a SOCKS5 proxy onto the tailnet.
// Authentication is required with the username "tsnet" and
// the value of proxy_cred used as the password.
//
// The HTTP server also serves out the "LocalAPI" on /localapi.
// As the LocalAPI is powerful, access to endpoints requires BOTH passing a
// "Sec-Tailscale: localapi" HTTP header and passing local_api_cred as
// the basic auth password.
//
// The pointers proxy_cred_out and local_api_cred_out must be non-NIL
// and point to arrays that can hold 33 bytes. The first 32 bytes are
// the credential and the final byte is a NUL terminator.
//
// If tailscale_loopback returns, then addr_our, proxy_cred_out,
// and local_api_cred_out are all NUL-terminated.
//
// Returns zero on success or -1 on error, call tailscale_errmsg for details.
extern int tailscale_loopback(tailscale sd, char* addr_out, size_t addrlen, char* proxy_cred_out, char* local_api_cred_out);

// tailscale_status_json writes the backend status (the JSON encoding of
// ipnstate.Status, the same struct LocalAPI's /localapi/v0/status returns)
// to *json_out as a NUL-terminated, malloc'd string. The caller owns the
// string and must release it with free().
//
// Unlike reading /status over the tailscale_loopback HTTP server, this
// goes through tsnet's in-memory LocalAPI listener: it keeps working when
// the OS reclaims the loopback TCP listener from a suspended process
// (observed on iOS), where the loopback address goes permanently stale.
//
// Returns:
// 	0     - success, *json_out is set
// 	EBADF - sd is not a valid tailscale
// 	-1    - call tailscale_errmsg for details (*json_out is NULL)
extern int tailscale_status_json(tailscale sd, char** json_out);

// tailscale_enable_funnel_to_localhost_plaintext_http1 configures sd to have
// Tailscale Funnel enabled, routing requests from the public web
// (without any authentication) down to this Tailscale node, requesting new 
// LetsEncrypt TLS certs as needed, terminating TLS, and proxying all incoming
// HTTPS requests to http://127.0.0.1:localhostPort without TLS. 
//
// There should be a plaintext HTTP/1 server listening on 127.0.0.1:localhostPort
// or tsnet will serve HTTP 502 errors.
//
// Expect junk traffic from the internet from bots watching the public CT logs.
//
// Returns:
// 	0     - success
// 	-1    - other error, details printed to the tsnet logger
extern int tailscale_enable_funnel_to_localhost_plaintext_http1(tailscale sd, int localhostPort);

// tailscale_errmsg writes the details of the last error to buf.
// 
// After returning, buf is always NUL-terminated.
//
// Returns:
// 	0      - success
// 	EBADF  - sd is not a valid tailscale
// 	ERANGE - insufficient storage for buf
extern int tailscale_errmsg(tailscale sd, char* buf, size_t buflen);


#ifdef __cplusplus
}
#endif

#endif
// lunabep: authenticated plaintext BEP sockets over TLS 1.3 to Syncthing
// peers, compiled into the libtailscale archive (Luna Vault).
//
// Every function returns 0 on success or a negative LUNABEP_ERR_* code. The
// message for the last failure on the CALLING THREAD is readable with
// lunabep_errmsg. Blocking calls may run from any thread.
//
// Connections come back as one end of an AF_UNIX socketpair carrying the
// plaintext BEP byte stream: read(2), write(2), shutdown(2), close(2).
// Closing the descriptor closes the TLS connection; the peer closing makes
// read(2) return 0 after the pending bytes.

#include <stddef.h>

#ifndef LUNABEP_H
#define LUNABEP_H

#ifdef __cplusplus
extern "C" {
#endif

enum {
	LUNABEP_OK = 0,
	LUNABEP_ERR_INTERNAL = -1,
	LUNABEP_ERR_INVALID = -2,        // bad argument (URL, device ID, bind address)
	LUNABEP_ERR_IDENTITY = -3,       // cert.pem/key.pem could not be loaded or created
	LUNABEP_ERR_UNREACHABLE = -4,    // TCP dial, timeout, or HTTP transport failure
	LUNABEP_ERR_HANDSHAKE = -5,      // TLS handshake failed
	LUNABEP_ERR_MISMATCH = -6,       // peer certificate hash != expected device ID
	LUNABEP_ERR_RELAY = -7,          // relay refused (not found, full, wrong token)
	LUNABEP_ERR_LISTENER_GONE = -10, // lunabep_accept woken by lunabep_close_listener
	LUNABEP_ERR_BAD_HANDLE = -11,    // unknown listener or tailnet handle
	LUNABEP_ERR_RANGE = -12,         // output buffer too small
	// An HTTP status s from a discovery server returns -(LUNABEP_ERR_HTTP_BASE + s).
	LUNABEP_ERR_HTTP_BASE = 1000,
};

// Copies the calling thread's last error message (NUL-terminated).
extern int lunabep_errmsg(char* buf, size_t buflen);

// Loads dir/cert.pem + dir/key.pem or creates them (ECDSA P-256, CN=syncthing,
// 20 years; files 0600, dir 0700). Writes the canonical device ID (63 chars).
extern int lunabep_identity(const char* dir, char* device_id_out, size_t outlen);

// Dials `tcp://host:port` (plain, or through the tsnet server `ts_handle`
// when non-zero) or `relay://host:port/?id=…`, completes the BEP TLS 1.3
// handshake, verifies the peer is `expected_device_id`, and returns the
// plaintext socketpair descriptor.
extern int lunabep_dial(const char* dir, const char* address_url,
                        const char* expected_device_id, int ts_handle, int* fd_out);

// Global discovery lookup. On 200 copies the server's JSON
// (`{"seen":…,"addresses":[…]}`). On another status returns
// -(LUNABEP_ERR_HTTP_BASE + status) and writes the Retry-After seconds.
extern int lunabep_lookup(const char* device_id, char* json_out, size_t outlen,
                          int* retry_after_out);

// Global discovery announce with the device certificate. `addresses_json` is
// `{"addresses":[…]}`. On 204 writes the Reannounce-After seconds; on another
// status returns -(LUNABEP_ERR_HTTP_BASE + status) and writes Retry-After.
extern int lunabep_announce(const char* dir, const char* addresses_json,
                            int* reannounce_seconds_out);

// TLS server listener on `bind_address` ("0.0.0.0:22000", ":0", …), on the
// tsnet server when `ts_handle` is non-zero.
extern int lunabep_listen(const char* dir, const char* bind_address, int ts_handle,
                          int* listener_out);

// Joins a relay in permanent protocol mode; invitations become accepted
// connections of the returned listener. Reconnects with backoff until closed.
extern int lunabep_relay_join(const char* dir, const char* relay_url, int* listener_out);

// Picks the lowest-latency public relay; writes `relay://host:port/?id=…`.
extern int lunabep_relay_pick(char* url_out, size_t outlen);

// Blocks for the next authenticated connection on `listener`. Writes the
// socketpair descriptor, the peer's canonical device ID, and a remote
// description (`tcp:1.2.3.4:5` or `relay:host`). Returns
// LUNABEP_ERR_LISTENER_GONE once the listener is closed.
extern int lunabep_accept(int listener, int* fd_out, char* peer_device_id_out,
                          size_t outlen, char* remote_out, size_t remotelen);

// Writes a JSON array of Syncthing address URLs to announce for `listener`.
extern int lunabep_listener_addresses(int listener, char* json_out, size_t outlen);

// Stops accepting and wakes blocked lunabep_accept callers.
extern int lunabep_close_listener(int listener);

#ifdef __cplusplus
}
#endif

#endif /* LUNABEP_H */
