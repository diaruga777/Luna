---
name: luna-code-setup
description: Set up Luna Code and the existing Luna Mac companion, including signing, pairing, cached builds and Mac-free refresh.
---

Read `claudedocs/code.md` and `claudedocs/code-local-refresh.md` in the Luna checkout at https://github.com/diaruga777/Luna. Preserve existing identities, app paths and user source changes.

- Run `python3 scripts/bootstrap_code_refresh.py` to prepare the pinned device library and register this checkout for the CLI/MCP launcher. Use `LUNA_CODE_CHECKOUT` when selecting a different checkout. Do not replace unrelated MCP servers.
- Build the `LunaCode` scheme and Luna Mac. Preserve Luna Mac's exact Apple Development signing certificate and installed bundle path; follow AGENTS.md. A free Personal Team build of the phone client can use `Config/LunaCodePersonalTeam.xcconfig`; it uses private storage and requires its own Mac pairing.
- Pair through Luna's existing Mac settings. The catalog, schedules and CLI use the same Luna Mac service. Local Wi-Fi, the user's separately installed Tailscale client, and an explicit Syncthing relay remain available through that connection.
- Mac-free refresh requires Wi-Fi, LocalDevVPN, an imported pairing file, an Apple account/team, an on-phone signing certificate and a cached development build. The phone can cache its own app. Import other IPAs through Refresh. Use the same team and bundle identity; preserve app groups, keychain and iCloud capabilities.
- Apple credentials and pairing material stay in this phone's non-synchronizing Keychain. Saving a password for automatic reauthentication is optional. Never copy credentials into source, logs, plugin configuration or agent prompts.
- Automatic refresh is opt-in and depends on iOS background runtime. Refresh before expiry; an already-expired Luna Code may need a computer to recover. Do not promise removal of Apple's account limits.
- Never install, launch or use WebDriverAgent on a physical phone. Use Simulator and synthetic tests for unattended checks. Report real Apple-account/device acceptance separately.
