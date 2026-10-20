# Overnight remote-install implementation status

2026-10-20. The user explicitly deferred physical iPhone testing and authorized
continued implementation without waiting for it. No physical installs, launches,
network/VPN changes, locking, rebooting or WebDriverAgent operations were performed.
An initial read-only CoreDevice identity query succeeded before that instruction;
it is **not** an installation acceptance result. No credentials or raw device logs
are checked in.

## Implemented

- Independent versioned invocation/job/install records, atomic local summaries,
  append-oriented JSONL/OSLog events, revision ordering, interrupted-work recovery,
  durable request acknowledgement and stable daily operation IDs.
- Queued committed-ref generic-iOS development builds; retained signed products,
  tree digests, device/profile/signature checks, installed-version/build readback,
  uncertain completion and ready-artifact reuse rather than nightly recompilation.
- A shared physical-device install lock for foreground and overnight jobs; scheduled
  installation never launches an app. Mac work continues after phone disconnection.
- Scene-independent task registration, daily 1–6 AM policy, runtime expiration,
  exactly-once task completion, opt-outs, production-path manual triggering,
  actual Wi-Fi checks, bounded IPv4/IPv6 LAN candidates and explicit remote control
  addresses. No automatic discovery, public pool selection or embedded Tailscale.
- A Mac-owned explicit Syncthing relay listener using existing TLS account trust.
  Phones dial it without a Tailscale dependency or competing relay registrations.
- Code diagnostics in shared connection settings, recent real invocations/jobs,
  last build vs confirmed install, status reconciliation, retry/cancel and redacted
  local/available-Mac journal exports. Missing remote logs are labelled explicitly.
- Provider-neutral framed device-flow streams with byte/frame/flow limits,
  endpoint-ID allowlists, monotonic renewable leases, flow replay rejection,
  cancellation, revocation and half-close; a TCP socket registry that rejects
  addresses not assigned to this device; non-synchronizing `ThisDeviceOnly`
  installation-key/proof primitives separate from the Luna account identity.
- Foreground physical-endpoint enrollment using a non-synchronizing phone key,
  a challenge copied into the configured Code app container through `devicectl`,
  and a signed proof read back through the same physical UDID's Apple connection.
  RPC authorization uses the authenticated TLS account, not a caller-supplied ID.
  Five-minute monotonic challenges, fixed UUID paths, bounded pending requests,
  durable owner-only bindings, idempotent completion and account/phone revocation
  are implemented. Forgetting the connection revokes persisted bindings too.
- A bounded Mac Apple-service adapter component and command under
  `tools/code-apple-adapter`: existing Mac-only host pairing record, pinned Apple
  device certificate, authenticated actual-UDID checks, named StartService ports,
  AFC upload, install-only request and exact revision readback/reconciliation.
  It rejects forwarding-app self-update and preserves unknown handoff completion.
  This component is **not yet composed into the Mac installer or phone streams**.
- A reproducible harmless fixture and explicit build/install/probe/collect harness
  under `tools/code-install-probe`. Install is separate from probe launch.

## Remaining integration (not represented as supported capabilities)

The production installer currently uses **native CoreDevice routing**. A working
Tailscale system route or pre-existing Apple bridge may carry it, but the installer
does not create that bridge or claim a verified underlay.

The physical enrollment path is now wired in production, but has not been run
against a phone. The restricted forwarding primitives are **not yet connected**
to the transport-aware adapter component. Syncthing's dedicated reverse streams
and the Mac's job-scoped private Unix broker are still unwired. The Go component
implements Apple traffic rather than a speculative port-range/CoreDevice bridge. Syncthing currently carries control RPCs, not installation traffic.
A relay byte-transfer pass is not an Apple installation pass. Production capability
negotiation therefore advertises retained/native installation and keeps
`deviceFlowProxy`, datagrams and proxy self-update false. No automatic public
listeners, arbitrary-host proxy, copied Apple pairing keys, speculative port ranges
or alternative installer were added to conceal this gap.

Connect the Mac Apple-service adapter to the enrolled identity
before enabling those capabilities. Required design evidence is which
phone-local Apple endpoints are reachable, how authenticated dynamic tunnel
endpoints are selected, and how replacement of the forwarding app affects final
readback. Physical checks can happen later as requested; none of these unknowns
are labelled supported or silently solved with a VPN extension/private entitlement.

Iroh is deferred: the reviewed `iroh-ffi` HEAD was
`3103bf5295be6d50c5272ff7a426e9b539f3f587`. An extra Rust/Swift binding toolchain
would not resolve the missing Apple-service adapter or self-update lifetime.
There is no Iroh dependency or inactive Iroh settings item. Research only:
[upstream bindings](https://github.com/n0-computer/iroh-ffi),
[Apple tunnel research](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md).
No code from those projects was adopted.

## Verification performed

Host: macOS 27.2 (26B5086k), arm64. Package tests use Xcode 26.2 (17C52) / Swift 6.2;
Luna Code simulator and companion compilation use Xcode 27.1 beta. The fixture
also compiles with Xcode 26.2. Builds were compilation-only: the persistent Luna
Mac app was not replaced, signed, staged or launched.

- `swift test --package-path LunaCodeKit`: 82 tests, two intentional skips,
  zero failures. New cases cover restart/disk errors, lost replies and stable IDs,
  artifact precedence, opt-out, stale terminal polls, readback identity, routing
  failure classes, escaping symlinks, frame limits/fragmentation, half-close,
  revocation, monotonic expiry, endpoint proofs and redaction. Enrollment cases additionally exercise container
  proof roundtrips, another phone/account/key, ID reuse, lost completion replies,
  persistence, expiry/restart, in-flight revocation and missing RPC authentication.
- `xcodebuild build -scheme LunaCode -destination 'generic/platform=iOS Simulator'`:
  passed with normal simulator signing. Git LFS archives were hydrated locally in
  the worktree before linking; no vendor archives were changed.
- `swift build --package-path LunaVaultTailscale --product LunaVaultMacCompanion`:
  passed. This does not launch or modify the persistent client.
- New adapter: ten top-level Go checks (plus two identity subcases) passed with
  race detection. Real local TCP/TLS plus a synthetic Apple-protocol fixture cover
  upload bytes, install/readback, lost reply, exact certificate/UDID rejection,
  self-update refusal, cancellation, message bounds, private Unix IPC, manifest
  permissions and local pair-record framing. These are **not real Apple installs**.
  `go vet`, `go mod verify` and compilation of the Mac command passed. No command
  queried the real Apple pairing daemon or a phone.
- Fixture simulator build: passed; no app launch or physical acceptance claimed.
- Go TLS/relay suite with race detection and a **real upstream private relay**:
  passed. Explicit loopback relay, public pools/status/NAT disabled; independent
  ephemeral identities, authenticated bidirectional 1 MiB + 17 byte transfer and
  stream closure. Test relay keys and raw logs remained outside the repository.

The relay was built from Syncthing v1.29.7,
`40660c5fb70556e9b1529de751de140c3142ade0`, under its upstream MPL-2.0 license.
It is a test tool only; no new runtime dependency or copied binary ships.
Reproduce (in an external scratch directory):

```sh
git clone --depth 1 --branch v1.29.7 https://github.com/syncthing/syncthing.git /tmp/private-relay-source
go -C /tmp/private-relay-source build -o /tmp/strelaysrv ./cmd/strelaysrv
/tmp/strelaysrv -listen 127.0.0.1:22167 -pools '' -status-srv '' -nat=false -keys /tmp/private-relay-keys
# In another terminal, from the repository:
LUNA_TEST_PRIVATE_RELAY='relay://127.0.0.1:22167' \
  go -C LunaVaultTailscale/GoSources/lunabep test -tags lunabep_standalone -race -count=1 ./...
```

Do not run the relay with its default public pool settings for this test. Without
the explicit environment variable the integration test skips, not passes.

## Setup and doctor guidance

First validate local signing, trust and Developer Mode with full Xcode, then use
the fixture's `doctor`, `build`, `install`, `probe` and `collect` commands from its
[README](../tools/code-install-probe/README.md). Check exact version/build readback
and the returned CoreDevice connection; do not infer routes from `100.*` addresses.
No Apple password belongs in configuration, logs or Git.

For phone authorization, build the Mac companion with the updated staging script
(which derives `LunaCodeBundleIdentifier` from `Config/Luna.xcconfig`; an explicit
`LUNA_CODE_BUNDLE_ID` override is available). Keep the required existing signing
identity and app location. In **Overnight Builds → Authorize This Phone**, choose
this physical phone while Apple's existing connection is available. The same
screen removes its authorization. This establishes a binding; it does not install,
launch, create a VPN or enable a remote installation capability. No enrollment
operation has been performed on the sleeping user's phone.

For remote **control**, pair locally first. In **Luna Mac → Overnight Builds**,
enter only the selected provider's explicit address. Tailscale uses the separately
installed clients and a `tcp://host:port` address. For Syncthing, configure the
Mac's existing preferences domain with `Code.relayEnabled = true` and
`Code.relayAddress = relay://…`, then restart the unchanged signed Mac app. Use
that same relay URL on iPhone. The companion owns the registration and accepts
only the already trusted account. A private relay works; public relay operators
can observe identifiers, timing and volumes despite end-to-end traffic encryption.
Disable the Mac preference and restart to stop registration. Changing phone
provider policy cancels its active attempt/control connection; it does not cancel
already accepted compilation.

Doctor outcomes still requiring device evidence: guest isolation/captive portals,
IPv6-only LAN and VPN underlay association, offline LAN installation, different
Wi-Fi with/without Tailscale, genuine overnight background allocation, lock/idle,
before/after first unlock, Mac sleep/restart, relay failure and Code self-update.
The full plan is **not complete** until required installation paths work and these
capabilities are integrated and verified. All deferred device matrix entries remain
pending rather than inferred from simulator or localhost results.

## Next integration pass

The pinned Go component uses go-ios AFC (`ca2c56d2c294ff702cadf4821edd30b069d3a264`,
MIT; notice included), but its own paired-certificate TLS/UDID checks and bounded
plist/IPC handling. It builds to `/tmp/luna-code-apple-adapter` for verification
only. No helper binary was staged in the persistent Mac app. See its
[README](../tools/code-apple-adapter/README.md) for the LCA1 private broker contract.

Remaining concrete work: phone-initiated dedicated TLS reverse-flow pool (separate
from BEP); Mac demultiplexing and a private job-token Unix broker; fresh endpoint
key proof bound to readiness generation/lease/account; phone endpoint grants only
for the two authenticated StartService results; retained-app IPA packaging and
`CodeArtifactInstalling` composition, transport-only fallback and truthful
capabilities/diagnostics. The enrollment `CodeService.handle` now receives the
real TLS account ID from the companion. Preserve that boundary. Do not add a
public arbitrary-port proxy or import an upstream accept-any-certificate verifier.
Native Tailscale/CoreDevice underlay and all physical acceptance remain pending.
