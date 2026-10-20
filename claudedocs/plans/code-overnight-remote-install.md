# Luna Code: overnight builds and installation across networks

Status: implementation handoff; no functionality implemented by this document.
Prepared: 2026-10-20. Baseline: `main` at `1aa56e146`.

## 1. Intended outcome and scope

Luna Code requests daily overnight background execution, connects to its paired
Luna Mac, submits due builds, and forwards installation traffic when the selected
pipe requires an app-side proxy. Luna Mac builds and signs, tries installation
over the local network first, then the configured remote pipe. Scheduled jobs
install only: they must never launch the newly installed app.

Local networking, Tailscale, and Syncthing-based transport are required paths.
Dumbpipe/Iroh remains in scope for a compatibility spike; ship it only if it fits
the same forwarding contract without a separate product architecture. Do not
reduce the implementation to Tailscale-only if the other required path is hard.

The latest request specifies **daily overnight attempts**. Preserve the existing
1–6 AM window in the phone's current time zone and per-scheme opt-in. The earlier
weekly proposal is not the default for this handoff. Keep cadence a policy value
so an interval can be added later without changing the wire protocol.

Settings must show the last actual attempt, its outcome, and the last confirmed
installation. Both ends retain useful, correlated diagnostic logs. Manual
triggering remains available, using the same engine as scheduled work.

This work does not extract repositories, publish a project, create a hosted
service, add a general VPN, require TestFlight, or guarantee daily execution.
Design the boundaries and setup diagnostics so later open-source extraction and
manual/agent-driven onboarding are straightforward.

## 2. Constraints and evidence

These are separate layers; success at one does not prove the next works:

| Layer | Responsibility | Required proof |
| --- | --- | --- |
| Scheduling | iOS grants runtime and Luna records an attempt | Real background invocation, not just a submitted request |
| Control connection | Phone authenticates to Luna Mac and submits a job | Mac persists the job before acknowledging |
| Pipe | Carries traffic between authenticated peers | Bidirectional transfer, cancellation and recovery |
| Apple device connection | Trusted Mac reaches the intended iPhone's services | Device preparation, authenticated tunnel and identity check |
| Installation | Signed build is installed | Installer completion and installed-product readback |

Apple chooses when and whether `BGProcessingTask` runs. It is not an alarm, an
unlock mechanism, or an unlimited runtime lease. A cold Mac build may outlast the
phone's allocation. Request an overnight attempt each day, handle expiration,
and report missed/unfinished work honestly. Do not use audio, location, repeated
background assertions, or another unrelated mode to keep a proxy alive. See
[BGProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask),
[earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate),
and [background runtime](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

Tailscale's separately installed client provides system-level routing and VPN
On Demand. Luna Code need not carry every byte on that path. Do not reintroduce
embedded tsnet as a hidden dependency of all providers. See
[Tailscale VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand).

Syncthing's relay protocol can carry opaque streams; it is not an IP VPN. Its
relay-control handshake and relayed data session are distinct, and the latter
needs end-to-end authentication/encryption supplied by the clients. A stock
Syncthing app does not proxy Apple services. Luna must provide that endpoint.
See [relay protocol](https://docs.syncthing.net/specs/relay-v1.html).

Dumbpipe uses Iroh and offers stream/TCP forwarding. Its use of QUIC internally
does not mean the CLI forwards arbitrary UDP. An iOS integration needs an
embedded library/binding, not a child process invoking the CLI. See
[Dumbpipe](https://github.com/n0-computer/dumbpipe) and
[Iroh bindings](https://github.com/n0-computer/iroh-ffi).

The [iPhone tailnet bridge](https://github.com/Viaaaron/iphone-tailnet-bridge)
demonstrates the proposed Mac-side discovery/forwarding approach, but has
machine-specific addresses/port ranges and does not establish that an ordinary
iPhone app can forward to its own development services. Use it as a reference,
not an installer to copy wholesale. [RemoteXPC research](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md)
describes Apple's paired device tunnels. [SideStore](https://github.com/SideStore/SideStore/blob/develop/README.md)
uses special on-device networking for local service access; it is not proof
that Luna can simply connect to `127.0.0.1` without such networking.

Source review is not device validation. Before adopting third-party code,
record exact revisions, licenses, tool versions, and tested iOS/macOS/Xcode
versions. Research references are not dependencies or instructions to run them.

## 3. Existing implementation to reuse and change

Paths below are relative to the repository root.

| Area | Current files and behavior | Planned change |
| --- | --- | --- |
| App wiring | `LunaCode/CodeAppDelegate.swift` registers background work and creates the shared Mac connection | Inject provider-neutral background coordinator and diagnostic store |
| Scheduling | `LunaCodeKit/Sources/LunaCodeUI/CodeNightlyScheduler.swift`, `LunaCodeKit/Sources/LunaCodeCore/CodeNightlyBuilds.swift` | Persist wake/attempt results, reconcile old jobs, install ready artifacts before submitting fresh work |
| Background transport | `LunaVaultTailscale/Sources/LunaVaultTailscale/LunaMacConnection.swift` | Replace the local-subnet-only background path with a Wi-Fi-required provider policy; preserve foreground Vault/Music behavior |
| Jobs | `LunaCodeKit/Sources/LunaCodeMac/CodeJobs.swift`, `CodeDeviceJob.swift` | Split durable compilation/artifact state from installation attempts and reconcile on restart |
| Models | `LunaCodeKit/Sources/LunaCodeCore/CodeProtocol.swift`, `CodeBuildCatalog.swift` | Add negotiated remote-install capabilities, artifact identity and attempt records without breaking older peers |
| Self-update | `LunaCodeKit/Sources/LunaCodeCore/CodeInstallHandoff.swift`, `LunaCodeKit/Sources/LunaCodeMac/CodeInstallHandoffGate.swift` | Distinguish ending UI monitoring from ending a pipe needed for the install |
| Transport | `LunaVaultTailscale/GoSources/lunabep/{transport,relay,api}.go`, `LunaVaultTailscale/Sources/LunaVaultTailscale/LunaVaultGoTransport.swift` | Reuse authenticated stream/relay primitives through adapters; add missing production relay wiring |
| Address resolution | `LunaLibraries/Sources/LunaVaultSync/VaultAddressResolver.swift` | Do not rely on its current manual-address short circuit for the new fallback policy |
| Settings | `LunaLibraries/Sources/LunaVaultUI/VaultConnectedSettingsViewController.swift` | Link a Code-specific attempt/diagnostic screen through injected composition |
| Mac composition | `LunaVaultTailscale/Sources/LunaVaultMacCompanion/CompanionController.swift` | Compose Code install service and provider adapters independently of Vault file policy |

Current accepted jobs survive phone disconnection, but startup marks interrupted
Mac jobs failed; the queue is not a durable installation queue. Current nightly
requests use a generic device build, then a single `devicectl` install attempt.
Successful compilation is already recorded separately. Preserve that useful
behavior, isolated committed-ref checkouts, signing resolution, cancellation,
app selection, and the prohibition on WebDriverAgent.

Current production Mac pairing uses authenticated TLS/BEP and direct addresses;
public relay publication is not fully wired. Do not advertise Syncthing remote
installation merely because low-level relay functions compile. Preserve existing
Vault/Music pairing, keys, App Group identifiers, and authorization behavior.

Shared Luna credentials synchronize across physical devices. They authorize an
account peer, not a particular iPhone. Enroll a non-synchronized install-endpoint
credential under that existing trust and explicitly bind it to the Mac's selected
Apple device identity during setup. Verify the binding against the actual Apple
connection; a phone name or caller-supplied UDID is not sufficient evidence. Do
not change the shared Vault identity just to distinguish installation endpoints.

## 4. First implementation milestone: prove the forwarding path

Do this before building a large settings UI or claiming remote-install support.
Use a harmless development-signed fixture app and a paired physical iPhone.
Never install, launch, or use WebDriverAgent on a physical iPhone.

1. Establish a local-network install-only baseline from Mac CLI. Record device
   identity, preparation requirements, signed product identity and exact output.
2. Put the phone and Mac on different Wi-Fi networks. Demonstrate Tailscale
   routing plus a bounded Mac bridge using the existing Apple pairing. Prove
   installation, not merely ping, Bonjour appearance, or device enumeration.
3. With Tailscale **disabled on both ends**, open an authenticated Syncthing-relay
   connection between Luna Code and Mac. Implement a minimal restricted iPhone
   forwarder. Determine whether a normal sandboxed app can reach the required
   local Apple services, on which interfaces, with which permissions and paired
   tunnel transport. Do not assume loopback reachability or private entitlements.
4. Determine the actual TCP/UDP requirements. Prefer a validated Apple-supported
   TCP tunnel mode if available on the supported versions. Otherwise specify
   datagram framing and bounded per-flow state over the stream pipe; measure it.
   Do not declare TCP forwarding sufficient based on the outer pipe's protocol.
5. Exercise foreground, real BGProcessingTask execution, expiration, screen lock,
   long idle, reboot before/after first unlock, and Wi-Fi changes. Establish which
   failures are reachability, pairing, service policy, or insufficient runtime.
6. Install an update of Luna Code itself through the app-hosted proxy. Determine
   when replacing the running app closes the proxy and how the Mac can confirm
   completion. A different fixture app does not prove self-update works.
7. Evaluate Dumbpipe/Iroh against the exact same stream contract and lifecycle.
   Record whether existing iOS bindings can support it with a small adapter.

Deliver a checked-in feasibility report with commands, redacted correlated logs,
versions, topology, observed restrictions and a provider capability matrix. No
device tests were performed in preparing this plan.

If local Apple-service access requires a separate VPN extension, jailbreak,
private entitlement, or a fundamentally different design, document the evidence
and ask the user to choose the concrete alternative. Do not silently add that
requirement or call the Syncthing path done. Likewise, explicitly resolve a
self-update failure before promising it. Keep reusable work and required
Syncthing scope; do not substitute a Tailscale-only completion.

## 5. Architecture and provider contract

```text
iOS schedule / manual trigger
          |
          v
attempt coordinator ---- authenticated control RPC ---- Mac job + artifact store
          |                                                   |
          |<------ prepare install / readiness ----------------|
          |                                                   v
          |                                  try native local device connection
          |                                                   |
          |                                     configured remote fallback
          |                                      /                  \
          |                             Tailscale routing       stream bridge
          |                                      |                  |
          +-- restricted Apple-service forwarder <--- Syncthing / optional Iroh
                                                 |
                                     Apple development services
                                                 |
                                         install; never launch
```

Separate three interfaces rather than treating all pipes as IP VPNs:

- **Peer transport** opens an authenticated, bounded, cancellable duplex stream
  to a paired peer and reports provider/capabilities and connection generation.
- **Device tunnel** exposes access to one authorized iPhone's discovered Apple
  service flows. It may use native routed networking or the stream forwarder.
- **Installer** takes a durable artifact, bound device identity and tunnel lease;
  it returns confirmed completion or a structured failure/unknown outcome.

The control API and install engine must not depend on `VaultFolderStore`, UI
controllers, a particular App Group, Tailscale IP prefixes, or a bundled Go/Rust
runtime. Host composition supplies identity, storage, logging and provider
adapters. Existing adapters may still use those dependencies internally.

Negotiate protocol versions and capabilities before submitting remote work.
Examples: install-only, retained-artifact install, device-flow proxy, datagrams,
readiness lease, attempt reconciliation. Older peers keep existing local behavior
and return a clear update requirement for new features. Never send raw proxy
frames into an existing BEP session or reuse file block requests as an unbounded
byte tunnel. Use a separately authenticated/versioned stream, or a deliberately
specified multiplexed extension with independent flow control.

Provider rules:

| Provider | Control and forwarding implementation | Dependencies |
| --- | --- | --- |
| Local | Existing authenticated direct control; Apple tools connect directly to the target device | Working peer-to-peer LAN; no internet required |
| Tailscale | Existing external-client TCP routing for control; native Apple tunnel through Mac bridge where validated | Both clients configured, VPN active, access rules permit traffic |
| Syncthing | Embedded discovery/relay adapter plus the same authenticated stream forwarder | No Tailscale login or stock Syncthing app; foreground/background Luna runtime during forwarding |
| Dumbpipe/Iroh, conditional | Embedded iOS endpoint and Mac adapter behind the same stream API | Reproducible library/bindings; no iOS subprocess, mandatory VPN, or provider-specific job system |

Use only explicitly configured/enabled providers. Try bounded local access first,
then the selected remote provider; an explicitly configured ordered list may
allow more than one. Do not silently log in, enable public discovery, publish
identifiers, or use another provider's relay. Show public relay metadata exposure
and allow a private relay address. Tailscale is optional for a Syncthing setup.

Control path and installation path can differ. Tag them separately in diagnostics.
Disable automatic public lookup/relay activity when the provider is off, and keep
public discovery policy isolated from other Luna clients.

Prefer the phone initiating the relay connection to a Mac registration, then
opening reverse installation flows over that established session. This avoids
requiring a public iPhone listener. Specify relay registration ownership so
multiple Luna clients sharing an identity do not fight over the same registration;
reuse a broker or enroll distinct authorized endpoint IDs as the adapter needs.

## 6. Scheduling, lifetime and installation flow

### Daily attempt

1. Register at app launch and resubmit the next request before starting work.
   Preserve opt-outs; record registration/submission failures. Do not require
   charging or public internet for the local path. Resolve provider network needs
   at runtime instead of making them global BGTask constraints.
2. Persist an invocation record immediately, including actual start time,
   intended window, local date/time zone, background/foreground reason, and ID.
   A scheduled date is not evidence that an attempt ran.
3. Require actual Wi-Fi association for scheduled submission and app-side
   forwarding. A default VPN path alone does not prove Wi-Fi presence. Test
   captive portal, guest isolation, IPv6-only LAN and VPN underlay detection;
   report unsupported/unavailable cases rather than guessing from `100.*`.
4. Reconcile prior accepted jobs and uncertain installs. Install an eligible
   ready artifact first; do not recompile it just because the last lease expired.
5. Submit missing due builds promptly, with stable operation IDs. The Mac must
   durably acknowledge before the phone records acceptance. Lost acknowledgments
   retry the same ID; explicit retries of completed failures get new attempt IDs.
6. Keep a bounded readiness lease while runtime permits. Send authenticated
   renewals and availability/capability information. Lease deadlines use local
   monotonic clocks, not an assumed shared wall clock.
7. On expiration, persist the local outcome, stop forwarding, close streams and
   release leases. Accepted Mac compilation continues. Complete the BGTask once,
   and reconcile final Mac results on the next foreground/background connection.

Acquire Local Network consent and any provider consent/login in foreground setup.
Load required keys/state with after-first-unlock protection; before-first-unlock
failure is a recorded skip, not a prompt or a weaker key-storage policy.
`setTaskCompleted(success:)` reports completion of that invocation's work; it must
not overwrite the separately recorded installation result.

Use one coordinated session/attempt for multiple schemes and serialize installs
per target phone. Isolate state by Mac identity, physical device, project/scheme,
and schedule generation. Time-zone/DST changes must not double-submit the same
local day. An unfinished old artifact is reconciled before the next day's build;
do not indefinitely accumulate one new artifact per missed install.

### Mac work and fallback

Build Debug for generic iOS with normal development signing and the selected
committed ref, independently of phone availability. Persist the signed `.app`
outside disposable checkout/DerivedData paths, with target device, bundle ID,
version, build, source commit, artifact digest and signing metadata. Validate
provisioning eligibility and artifact integrity again before installation.

When ready, attempt the intended device via native local connectivity. If the
failure is a transport/reachability failure, try the configured remote path.
Pairing, signing, device-lock and identity failures must not be treated as routing
problems and blindly retried across every pipe. Log every attempted path and why
a candidate was rejected. Never select another phone when the saved one is absent.
Inspect the actual CoreDevice connection/interface when attributing a local or
remote success; Apple's automatic transport choice must not be mislabeled as a
local test. Remove stale synthetic advertisements before selecting a native path.

For an app-hosted pipe, require a live, generation-bound readiness lease before
connecting. A stale address or old Bonjour advertisement cannot stand in for an
active forwarder. A lease may end while compiling; retain the artifact and mark
installation waiting for the next connection. Native local/Tailscale installs
may continue independently when the iOS task expires; do not make their readiness
artificially depend on Luna Code after job acceptance.

Retain one actionable artifact per scheme/device by default plus anything being
installed or awaiting reconciliation, with a documented disk quota. Never delete
an uncertain install's evidence before reconciliation. After Mac restart, restore
ready artifacts and install attempts; interrupted compilation can fail explicitly.
Do not reconstruct an in-memory job queue as though an interrupted process lives.

Use `devicectl` with structured JSON diagnostics where the validated bridge can
expose the device to CoreDevice. If a provider requires a transport-aware installer
instead, prove the signed-app install/readback path in milestone 1, hide it behind
the installer API, and record the version/license implications. Do not build a
whole alternative installer on speculation.

Readback must identify this artifact, not merely an already-present bundle ID.
Use distinct version/build metadata or an accessible embedded build marker to
disambiguate revisions. If the available readback cannot distinguish the result,
record verification unavailable/unknown rather than claiming a confirmed update.

Do not switch pipes mid-install and replay bytes. Close the old attempt, establish
a new tunnel, reconcile device state, then retry the immutable artifact as needed.
Use bounded retry/backoff within the current lease; persist waiting state between
wakes. Disabling a schedule prevents new submissions; cancellation of already
accepted work remains explicit and must close its proxy listeners too.

### Proxy and self-update lifetime

Create narrow Mac listeners on demand. Prefer loopback; if CoreDevice requires a
LAN advertisement/listener, bind only the validated interface with an authenticated
device session and bounded lifetime. Clean up on success, failure, cancellation,
restart and interface change. Do not spawn hundreds of port forwarders or write
permanent hosts-file entries as the product design.

Forward only the paired phone's validated Apple service endpoints, including
validated dynamic tunnel endpoints. Enforce port/address/protocol bounds and
stream/byte/memory limits; no arbitrary remote host dialing. Recheck identity
after each fresh Apple handshake. Luna peer authorization is not Apple pairing.
The Mac retains Apple host pairing secrets; the iOS proxy should forward opaque
Apple traffic without receiving the host's private pairing keys.

Keep TLS peer authentication and Apple pairing authentication independent of
provider discovery, relay IDs, IPs and Iroh tickets. Encrypt relayed app traffic
end to end, authorize every proxy session, reject revoked/unknown peers and
replayed lease/session tokens, and do not log tickets or key material.

Updating Luna Code is special: the app carrying the stream may be terminated by
its own replacement. Persist intent before installation; finish system progress
UI if needed **without closing a still-required forwarder**. Treat a broken pipe
after handoff as unknown completion, never as success. If the old app cannot
remain alive long enough, defer to a proven independent path or report that
self-update is unsupported for that pipe pending a design decision. No automatic
post-install launch is allowed to recover the proxy. Reconcile on the next
user/system launch. Do not hide this limitation behind the existing handoff gate.

## 7. Persisted attempts, settings and comprehensive logs

Introduce an append-oriented attempt journal with a current summary on both
ends. Use an explicitly versioned local store with atomic writes/migrations;
do not overload the current `nightlyFailure` string as the entire state machine.

Record three related entities: iOS invocation, durable Mac build/artifact job,
and each install attempt. One build can have multiple installs; one invocation
can reconcile older work. Correlate `invocationID`, `requestID`, `jobID`,
`artifactID`, `installAttemptID`, `sessionID`, target and provider generation.

Minimum durable fields:

- Scheduled/requested time, actual invocation start/end, app lifecycle reason,
  time zone, app/OS versions, and next requested date.
- Chosen Mac, bound physical device, scheme/ref/commit and artifact identity.
- Acceptance, compilation completion, install start/completion/readback times;
  separate last-attempted, last-built and last-confirmed-installed timestamps.
- Control provider and installation provider, ordered candidate outcomes,
  service/tunnel stages, transfer byte totals and durations, expiration/cancel
  reason, structured error domain/code plus concise user-facing recovery text.
- State revision and last synchronization time. Cross-device timestamps do not
  determine event order; use IDs/revisions and per-process monotonic durations.

States must distinguish `started`, `skipped` (for example no Wi-Fi), `accepted`,
`building`, `waitingForPhone`, `installing`, `succeeded`, `failed`, `expired`,
`cancelled`, and `unknownCompletion`. These are separate invocation/job/install
dimensions, not one giant job enum. A compile success or acknowledged request is
never installation success. Stale in-progress records after a crash become
interrupted/unknown and reconcile; do not stay green or running forever.

Settings initially needs only a clear diagnostic screen:

- Last actual attempt time and outcome; failure stage/reason when applicable.
- Last successful build and last confirmed installation, selected provider,
  next requested attempt, and most recent status synchronization time.
- Recent attempt list with per-stage details, **Try Now**, **Refresh Status**,
  and **Export Diagnostics**. Try Now uses production checks but bypasses only
  the overnight window; debug task simulation is a separately labelled tool.

If there is no recorded wake, show no recorded attempt rather than a fabricated
failure. If the phone cannot fetch the Mac outcome, show its last-known status as
pending/stale. Preserve the last success when a newer attempt fails. On reconnect,
merge by IDs/revisions; never replace a newer terminal result with a stale poll.

Use structured OSLog plus rolling JSONL files on iPhone and Mac. Log scheduling
registration/submission, invocation, Wi-Fi/provider checks, DNS/discovery, relay
registration/session stages, auth outcome, forwarding lease/open/close, listener
lifetime, build stages, installer exit/error details, readback and reconciliation.
Capture bounded installer stdout/stderr/JSON and compiler logs; use counters and
sampled transfer progress instead of payload or per-packet dumps.

Proposed defaults: 30 days/200 attempt summaries and 20 MB of transport logs per
endpoint, with separately quota-managed existing build logs/artifacts. Log export
includes a manifest, versions, capability report and matching local/available Mac
logs, with explicit missing-remote-log markers. Redact credentials, pairing keys,
auth tags, tickets, relay session keys, source/file contents and sensitive paths;
use consistent pseudonyms for device IDs and addresses. Apply existing iOS
after-first-unlock protection and owner-only Mac permissions. No telemetry service.

## 8. Implementation sequence and acceptance

Each stage is a small verified commit; update `claudedocs/code.md` and shared
connection docs with actual behavior, not promised behavior.

1. **Feasibility and provider decision.** Complete section 4 with a fixture and
   real background/lock cases. Record required versus optional capability results.
2. **Core contracts and durable state.** Add protocol negotiation, attempt models,
   artifact/install separation, idempotency and restart reconciliation. Wire
   journal events from existing local jobs before changing transport behavior.
3. **Restricted tunnel and required adapters.** Implement local and external
   Tailscale paths, then embedded Syncthing control/relay + proxy with Tailscale
   disabled. Add Iroh only if the same contract passes with a bounded adapter;
   otherwise record a specific defer decision, not a nonfunctional settings item.
4. **Background coordinator.** Replace the subnet-only scheduled session; make
   ready-artifact retry precede compilation; implement leases, task expiration,
   policy migration and installation-only cancellation semantics.
5. **Diagnostic settings and exports.** Expose real recorded outcomes and both
   endpoint logs. Confirm that export survives disconnection and self-update.
6. **Integration verification and handoff docs.** Run the matrix below, record
   actual versions/results, and write minimal setup/doctor guidance sufficient
   to reproduce the supported configurations now.

Meaningful automated coverage:

- Clock-injected schedule/DST/opt-out decisions; invocation bookkeeping even
  when connection fails; migration of existing daily toggles and history.
- Lost acceptance reply, duplicate submit, ready artifact reuse, interrupted
  build/install, restart, cancellation and terminal-status merge ordering.
- Stream framing/limits, fragmented reads, backpressure, half-close, expiration,
  peer revocation, replay, target mismatch and datagram boundaries if supported.
- Provider contract tests over a real local private Syncthing relay, not only
  mocks; prove fallback order and that a disabled provider makes no connections.
- Artifact identity/provisioning checks, installer/readback failures and unknown
  completion. Verify no scheduled code path invokes process launch.
- Diagnostic persistence, log rotation and secret-redaction fixtures.

Real-device acceptance matrix (simulators cannot prove these):

| Scenario | Evidence required |
| --- | --- |
| Same LAN, internet absent, no VPN | Install-only success and confirmed target |
| Different Wi-Fi networks, Tailscale | Native bridge install with recorded path |
| Different Wi-Fi networks, Tailscale off on both | Syncthing-relayed install and readback |
| Optional Iroh | Same contract and network/lifecycle cases, or documented defer reason |
| Cold build outlasts iOS allocation | Build retained; later wake installs without recompiling |
| Device locked/idle; before/after first unlock | Observed capability or actionable failure, no unlock workaround |
| Wi-Fi loss, relay outage, Mac sleep/restart | Correct attempt state, bounded retries, later reconciliation |
| Repeated/simultaneous triggers and schemes | One accepted operation, serialized target installs |
| Wrong/revoked peer, stale identity/address | Rejected without forwarding to a different device |
| Luna Code updates itself over each enabled pipe | Verified success or explicit capability limit; no forced relaunch |
| Genuine overnight background run | Attempt journal and logs prove execution without a visible scene |

Use Apple's CLI for build/install/inspection; no physical-device UI automation
through WebDriverAgent. Test scheduled installation independently of app launch.
When rebuilding the persistent Luna Mac companion, obey `AGENTS.md`: exact
existing Apple Development identity, bundle identifier/location preserved, and
signature verified before launch. Never use the default ad-hoc relaunch path.

Done means local, Tailscale and Syncthing installation are demonstrated, state and
logs tell the truth under failure, no scheduled launch occurs, and limitations
are documented. If a required feasibility gate fails, report the blocked part
and concrete decision needed; a mocked or foreground-only tunnel is not a
completed overnight remote-install feature.

## 9. Prepare for standalone open-source release without extracting now

Create narrow package boundaries, with names chosen during implementation:

- Shared peer identity, authentication, stream interfaces and provider adapters
  can later move to a transport package consumed by Code and Vault.
- Build orchestration, artifact persistence, restricted device tunnel and
  installer live in Code-facing packages independent of Vault storage/UI.
- iOS scheduling/UI and Mac app composition inject paths, credentials, bundle
  configuration and logging. No new core dependency on `LunaAppConfig`, shared
  Vault folder policy, premium access, a particular username, Blitz, or this repo.

Keep current compatibility wrappers, bundle IDs, keychain/App Group access and
state migration intact. Do not extract public repositories or rename signing
identities as part of this task. Track licenses/notices for Go/Rust libraries and
any Apple-protocol implementation; prefer reproducible source builds with pinned
versions/checksums over copied developer-machine binaries.

Design the future setup surface around one versioned configuration and the same
operations for a human guide and an agent CLI: `doctor`, `setup`, `pair`,
`providers`, `build`, `install`, `attempts`, `logs`, `reset/uninstall` (proposed
verbs, not commands that exist yet). Provide structured JSON, stable exit/error
codes, resumable/idempotent steps, dry-run/status, and a fully local first-build
path before enabling a remote provider.

The future setup checklist should discover/validate Xcode + iOS SDK/CLI tools,
complete first-launch/component checks, guide Apple account/team signing and
device trust/Developer Mode, bootstrap the first iPhone app via USB, configure
the chosen provider, test local then cross-network install, and verify a recorded
attempt. Full Xcode is required; Command Line Tools alone are insufficient.
Automate available downloads/installation where authorized, but expose Apple ID,
license, administrator, iOS trust/restart, and privacy prompts as explicit human
steps. Never claim an agent can bypass them or needs a user's Apple password.

Do not require all provider toolchains for a single-provider install, default to
this machine's `en0`/fixed address, or assume a paid account/entitlement without
reporting the applicable signing limits. Document provider outages, public relay
privacy/throughput, client login expiry, Xcode/iOS compatibility and background
limitations as actionable doctor results. Persisted credentials, Apple pairing
records and tickets never belong in Git, generated example configs or logs.

Repository extraction, hosted documentation, release binaries, full bootstrap
scripts, and a clean-machine one-shot agent setup trial are future deliverables.
The current implementation should leave the interfaces and diagnostics needed
for those deliverables, rather than building the entire distribution system now.
