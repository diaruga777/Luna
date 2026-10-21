# Overnight install feasibility fixture

This standalone UIKit app is generated into a disposable directory. It has no
private entitlements, Luna credentials, app-group access, VPN extension, pairing
keys, remote listener or WebDriverAgent dependency. No physical checks run by
default. Keep output outside Git: CoreDevice logs contain private device metadata.

Use full Xcode (select the intended version with `DEVELOPER_DIR`), Python 3 and
the repository's existing Ruby `xcodeproj` dependency:

```sh
python3 tools/code-install-probe/run.py doctor
python3 tools/code-install-probe/run.py build --simulator --output /tmp/install-probe-sim
python3 tools/code-install-probe/run.py build --team YOUR_TEAM --output /tmp/install-probe-device
python3 tools/code-install-probe/run.py install --device YOUR_PHYSICAL_UDID --output /tmp/install-probe-device
```

`install` never launches. It verifies the selected physical device through
CoreDevice, verifies the product signature and compares installed bundle,
version **and build**. If readback cannot identify that revision it returns
`unknownCompletion` (exit 3). Use a fresh `--build-number` for each revision.
The transport reported by CoreDevice is preserved; a successful native command
does not prove which underlay carried the connection.

Launch the fixture separately for an explicitly foreground-only service probe:

```sh
python3 tools/code-install-probe/run.py probe --device YOUR_PHYSICAL_UDID --output /tmp/install-probe-device
python3 tools/code-install-probe/run.py collect --device YOUR_PHYSICAL_UDID --output /tmp/install-probe-device
```

Allow Local Network access in foreground. The probe checks TCP 62078 and 58783
on **only its own assigned interfaces**, plus its own discovered RemotePairing
port. An optional `--port` must be captured from the current phone's Apple
service/tunnel negotiation; it is never scanned. The probe sends no Apple
protocol payloads. A TCP connection is not Apple authentication or installation
proof. Logs use interface names and ports rather than addresses or Bonjour TXT.

The app's **Schedule Background Check** requests 1 AM in the current time zone.
Only an actual `reason: background` invocation proves that iOS ran it. Debug
simulation and CLI launch do not. The fixture records expiration, lifecycle and
protected-data availability, with after-first-unlock file protection. Export
Results also shares the local JSONL file without a Mac connection.

Next physical checks: same-LAN install with internet/VPN absent, different Wi-Fi
with Tailscale, different Wi-Fi with Tailscale off and an authenticated Syncthing
pipe, actual background allocation, screen lock, reboot, network loss and
Luna Code replacing itself. These remain acceptance work; do not convert a
successful simulator build or loopback relay test into a device result.
