> Archived: Luna Code was extracted into [Orbit](https://github.com/diaruga777/Orbit) on 2026-10-21. Active implementation and setup documentation now live there.

# Overnight remote-install implementation status

2026-10-21. The user explicitly deferred physical iPhone testing and authorized
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
  The component is now composed into the Mac installer and dedicated phone streams;
  availability is advertised only when the staged helper executable is present.
- A reproducible harmless fixture and explicit build/install/probe/collect harness
  under `tools/code-install-probe`. Install is separate from probe launch.

## Production integration and remaining verification

The Mac first tries native CoreDevice routing. Only a transport failure before
handoff permits fallback; pairing, signing, lock, identity and unknown-completion
outcomes do not blindly try another pipe. Native routing keeps its truthful
`nativeAutomatic` label. The app-hosted route works with the selected explicit LAN,
Tailscale TCP or Syncthing relay address and labels its underlying network as
unverified, rather than inferring it from an IP prefix.

A phone proves its enrolled key for a fresh readiness generation, polls authenticated
control RPCs for bounded Apple-service demands, and initiates a fresh independent
TLS stream for each demand. Each byte stream proves that phone key again against
a one-use Mac challenge. Dedicated LCDF magic is demultiplexed before BEP; existing
BEP bytes are replayed unchanged. No public iPhone listener or Apple bytes in BEP
file blocks are used. Account trust alone cannot impersonate a physical endpoint.

Readiness uses monotonic 60-second renewable / 900-second hard deadlines. Phone
flows renew every 20 seconds while actual Wi-Fi and runtime permit. Expiration,
revocation, cancellation or policy change closes streams. The invocation keeps a
bounded readiness window (up to 840 seconds, subject to earlier iOS expiration).
Accepted builds outlast that window and retain their artifacts for another wake.

The job-scoped Mac Unix broker is owner-only, token-bound, limited to eight active
and 32 total connections, and accepts only the pinned helper's three named service
kinds. Dynamic ports come from its authenticated Apple StartService responses;
no public RPC accepts caller-selected host/port forwarding. The phone connects
only to its own current Wi-Fi addresses. The Go helper explicitly declares full
close on Unix EOF; normal stream clients retain half-close. This avoids guessing
lifetime from Darwin's Unix hangup flag. Route/session intent is durably saved
before the helper starts. Lost handoff results remain unknown and readback comes
before retry. The retained `.app` is packaged without changing its signed contents.

`script/build_and_run.sh` builds the pinned Go helper before touching the existing
app, collects compiled-module/Go runtime license notices, signs the nested helper
with the same requested Mac identity, and verifies the full bundle. This script
was **not run against the persistent app**. Compilation, notice collection and
shell syntax checks passed. A staged executable enables proxy capability reporting;
missing helpers retain native-only capabilities. Datagrams and app-hosted self-update
remain false. Luna Code must use an independent Apple path to update itself.

Production composition and the combined automated integration are implemented.
The synthetic Apple-protocol fixture passed through the checked-in Go/TLS archive,
a real upstream private Syncthing relay, LCDF demultiplexer, per-flow phone-key
proof, phone proxy and Swift Unix broker. Exact readback/upload bytes, unknown
handoff reconciliation, wrong UDID and wrong certificate were checked. Control
polling calls the real hub directly; Apple services and the payload are synthetic.
This is not a physical install or proof of background allocation. All physical
enrollment, reachable-Apple-service, lock/background, route and self-update
acceptance checks remain pending as requested. No phone or network setup changed.

The combined test exposed strelaysrv v1.29.7's near-simultaneous session-join race:
it consumes keys before a nonblocking send into an unbuffered session mailbox.
The receiving Go adapter now gives the initiator a cancellable 10 ms head start.
All Mac/device/simulator transport archives were rebuilt from the same pinned
Tailscale revision with that source change. The final combined run passed all
four scenarios in 4.953 seconds without join refusals. Failed dials still have
the normal bounded pending-demand retry; used grants and Install handoffs are
never blindly replayed. TLS, identity, frame and lease checks are unchanged.

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

- `swift test --package-path LunaCodeKit`: 92 tests, two intentional skips,
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
- Transport/companion Swift suite: 17 tests, one intentional opt-in integration
  skip without its environment, zero failures. The integration test separately
  passed with a real local private relay and race-instrumented Go fixture binary.
  Existing checks include unchanged BEP hello replay, dedicated Apple-frame replay
  and cancellation of stalled classification.
- Reverse-flow cases exercise fresh physical-key proofs, wrong/shared-account key,
  replay, generation change, lease expiry, renewal replay, revocation, private Unix
  roundtrip/token rejection, half-close and full-helper-exit cleanup. Fallback cases
  reject every non-transport/unknown-handoff transition.
- New adapter: ten top-level Go checks (plus two identity subcases) passed with
  race detection. Real local TCP/TLS plus a synthetic Apple-protocol fixture cover
  upload bytes, install/readback, lost reply, exact certificate/UDID rejection,
  self-update refusal, cancellation, message bounds, private Unix IPC, manifest
  permissions and local pair-record framing. These are **not real Apple installs**.
  `go vet`, `go mod verify` and compilation of the Mac command passed. No command
  queried the real Apple pairing daemon or a phone.
- Fixture simulator build: passed; no app launch or physical acceptance claimed.
- Go TLS/relay suite with race detection and a **real upstream private relay**:
  passed, including three repeated runs after the session-join fix. Explicit loopback relay, public pools/status/NAT disabled; independent
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
The required installation paths are wired and combined automated integration
passes. Every deferred physical matrix entry remains pending; simulator and
localhost results are not substituted for device evidence.

## Handoff and deferred acceptance

Implementation and autonomous checks are complete; physical acceptance is deferred
by the user's explicit instruction. The overnight follow-up can be disabled after
merging this pass. No physical evidence is inferred and no further unattended
phone/network changes are planned. Final compilation of Luna Code for the generic
iOS simulator and the Mac companion passed against the rebuilt archives.

To reproduce the combined check, build the upstream private relay above and run:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer \
LUNA_TEST_RELAY_BINARY=/tmp/strelaysrv \
  tools/code-apple-adapter/integration/run.sh
```

The runner uses only an ephemeral loopback relay with public pools/status/NAT
disabled and cleans up its test keys and tokens. It compiles a test-only Go
fixture, not a command that can bypass production pairing. Four scenarios cover
the complete data path; physical enrollment, Wi-Fi policy, Apple service exposure,
iOS background execution and actual signed-product acceptance still need devices.
The [adapter guide](../tools/code-apple-adapter/README.md) details the test boundary.

Before eventual deployment, stage Luna Mac with the exact existing development
identity/location and verify the nested helper and full app signature. Authorize
the phone through the foreground Apple container exchange. If the proxy capability
is absent, inspect helper packaging/signing. If readiness is absent, inspect
phone authorization, the actual Wi-Fi policy and iOS runtime. Pairing/identity
failures need the Apple trust/authorization path, while unknown completion needs
revision readback before retry. App-hosted Code self-update remains unsupported;
use an independent native Apple path. Then record the deferred physical matrix
above, including the actual route and background/lock conditions.

The pinned Go component uses go-ios AFC (`ca2c56d2c294ff702cadf4821edd30b069d3a264`,
MIT; notice included), but its own certificate pinning/UDID and bounded plist/IPC
handling. Its [README](../tools/code-apple-adapter/README.md) describes the LCA1 local
contract, including `fullCloseOnEOF`. Private IPC paths must be short (under 100
bytes). Normal macOS temporary directories can exceed that bound; the broker
atomically creates `/tmp/lc-<UUID>` with mode 0700. All jobs remove it on completion.

No helper binary or updated companion was staged/launched on the user's Mac.
No physical phone operation was performed. Preserve the existing exact development
signing identity and app location when eventually staging a persistent build.
