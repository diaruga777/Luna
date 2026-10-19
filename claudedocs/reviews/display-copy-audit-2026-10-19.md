# Display copy audit — 19 October 2026

Reviewed display strings across Luna, Keyboard, Music, Vault, Code, Writer,
the Mac companion, Safari, widgets, share/action extensions, permission prompts,
and shipped and optional plugin manifests. The review covered the shared English
catalog and inline strings in app and library sources.

## Changes

- Rewrote settings, setup, empty states, errors, and Shortcuts descriptions around
  useful outcomes and next steps. Removed architecture descriptions, prompt-like
  rules, and summaries of visible controls.
- Removed plugin priority and hook names from the draft review screen. Kept
  permissions, supported sites/content, validation results, and limitations.
  Hook validation still runs and its failures still appear in the test result.
- Removed internal matched-field names from Vault search results. Simplified
  pairing, search, storage, transfer, and recovery copy, including older screens.
- Replaced Keyboard’s Unicode implementation details and “Cosmetic” terminology
  with search and suggestion wording. Removed the redundant language footer.
- Shortened Music’s queue descriptions and download settings; removed repeated
  transcript/chapter empty-state descriptions. Simplified Code build messages.
- Rewrote all six bundled and fourteen optional media plugin descriptions.
  Regenerated the optional media bundle outside app resources.
- Kept privacy, permissions, destructive-action consequences, and useful technical
  terms needed for a task. Internal prompts, protocols, IDs, logs, and test/stage
  descriptions remain development material.
- Added permanent writing guidance to `AGENTS.md` and `claudedocs/strings.md`.
  Made Writer’s dynamically constructed localization keys statically discoverable
  by the existing catalog checker.

| Before | After |
| --- | --- |
| “Every Unicode emoji has keyword mappings, including skin tones, flags and joined sequences…” | “Tap an emoji to add your own keywords.” |
| “Testing the draft in an isolated temporary runtime…” | “Testing the plugin…” |
| “Confirm fingerprint and prepare enrollment” | “Confirm Mac and Continue” |
| “Its active index model is unavailable…” | “Couldn’t add this file. Rebuild search in Settings, then try again.” |
| A paragraph specifying podcast queue/cursor rules | “Pick up where you left off, then continue with unplayed episodes from the shows you follow.” |

## Verification

- `scripts/strings_sync.py --check`: 1,298 entries / 1,234 scanned keys in sync.
- Shared-catalog format arguments preserved; strings and changed permission
  property lists pass `plutil -lint`; `git diff --check` passes.
- All twenty plugin manifest headers parse; all fourteen media sources match the
  regenerated `.lunabundle` byte for byte.
- Focused `LocalizableStringsTests` and `PluginDraftValidatorTests`: eighteen
  tests passed on the iOS 26.2 iPhone 17 Pro simulator.
- Visually inspected the plugin draft review and Keyboard home screens on that
  simulator. No physical-device automation was used.
- Simulator builds passed for Luna, Vault, Writer, Keyboard, Music, and Code
  using Xcode 26.2. Keyboard, Music, and Code used separate build folders to
  avoid stale package-linking output between schemes.
- The Mac companion built with `swift build --product LunaVaultMacCompanion`.
- The full test suite and every runtime screen were not exercised; this was a
  source-wide copy review with focused tests and representative visual checks.
