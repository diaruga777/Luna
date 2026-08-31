# Vendored TailscaleKit

These sources come from `swift/TailscaleKit` in
https://github.com/tailscale/libtailscale at commit
`80771313ac4127973677c993889fe215abcf1fbd` (BSD-3-Clause, see LICENSE).
The C library they wrap is the committed `Vendor/LibTailscale.xcframework`,
built from the same commit by `scripts/build_libtailscale.sh`.

Why vendored instead of the upstream framework build:

- Upstream ships an Xcode-project framework, not a Swift package. Its build
  needs a Go toolchain, so Luna commits the built C archives and compiles the
  small Swift wrapper from source.
- Upstream's `OutgoingConnection` exposes only `send`, and
  `IncomingConnection` only `receive`; both keep the socket private. Vault's
  Mac protocol needs one bidirectional stream, so Luna does not vendor those
  two files and adds `TailscaleSocket.swift` (fd-level dial/listen/accept)
  instead. `Listener.swift` is also not vendored for the same reason.

Luna changes inside vendored files are marked with a
"Luna vendoring change" comment and limited to:

- `import LibTailscale` where C symbols are used (the upstream framework used
  a bridging header).
- `TailscaleNode.swift` also declares the `TailscaleHandle` /
  `TailscaleConnection` / `TailscaleListener` typealiases and `NetProtocol`,
  which upstream declares in the un-vendored `OutgoingConnection.swift`.
- `TailscaleNode.swift` makes `up()`, `close()`, and `statusJSON()`
  `nonisolated` and adds a `nonisolated interrupt()`, so a caller can
  interrupt a blocked `tailscale_up` from another thread instead of the
  close queuing behind it on the actor. A `closeOnce` guard keeps
  `tailscale_close` to exactly one call across `interrupt()`, `close()`,
  and `deinit`.

Known upstream quirk kept as-is: `TailscaleNode.down()` calls `tailscale_up`.
Luna never calls `down()`.

To update: re-run `scripts/build_libtailscale.sh`, diff upstream
`swift/TailscaleKit` against this directory, and re-apply the marked changes.
