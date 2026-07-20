# Wave 2A — LunaAudioPlayback + Luna/MiniPlayer

Read `PLAN.md` hard rules and `audits/audio.md` (structure map + cited sections) first.
Files: `LunaLibraries/Sources/LunaAudioPlayback/*`, `Luna/MiniPlayer/*`,
`Luna/AudioPlaybackWiring.swift`, `Luna/AudioScriptPipelineWiring.swift`, and (item 3
only) `LunaReaderUI/ReaderAudioLauncher.swift`. One commit per item.

Constraint reminder: `ArticleAudioEngineTests` is environment-fragile (CLAUDE.md) — keep
`ArticleAudioEngine`'s API shape stable except where a plan item says otherwise.

1. **Session-reset dedupe** (audit §2.3/§2.4 region 5). Extract the verbatim block shared
   by `AudioPlaybackCenter.beginPlayback`/`restartPlayback` into one private helper. The
   ~11 stored properties it resets should move behind a named private struct (e.g.
   `RenderSessionCursor`) ONLY if that stays a pure mechanical regrouping; otherwise a
   plain `resetRenderSession()` helper is enough. Do not reorder any reset.

2. **`avgSecPerWord` dedupe** (§2.3): three verbatim computations → one private computed
   property.

3. **Cross-module word-indexing dedupe** (§2.3): make `AudioWordIndexing` public
   (explicit `public` API + doc comments on parameter/return semantics), then reimplement
   `AudioWordEventTokenMapping` (`LunaReaderUI/ReaderAudioLauncher.swift`) on top of
   `wordStartUTF16Offsets`/`wordOffset` instead of its own duplicate UTF-16 scan.
   `LunaReaderUI` already depends on `LunaAudioPlayback`. Behavior must be
   character-for-character identical — `LunaTests/AudioMiniPlayerTests.swift` and the
   RSVP resync tests exercise this; run them.

4. **`AudioPlaybackCenterDataSource` protocol** (PLAN.md contract; app-shell audit §2.1
   flagged the cluster). Replace the three stored closures on `AudioPlaybackCenter`
   (`nextItemProvider`, `scriptProvider`, `scriptPrefetchHandler`) with
   `weak var dataSource: AudioPlaybackCenterDataSource?` — one protocol, three
   requirements whose signatures mirror the closures exactly. One conformer: a new
   app-shell type (e.g. `AppAudioPlaybackDataSource` in `Luna/AudioPlaybackWiring.swift`)
   installed once at launch, replacing the two separate installers' assignments (keep the
   two wiring files' *install moments* unchanged — if the closures were installed at
   different launch phases, verify collapsing them into one assignment doesn't change
   when the center can first pull a script; if it does, keep two-phase installation by
   letting the conformer internally gate, and say so in your report). Nil dataSource must
   behave exactly like the previously-nil closures (extensions never install one).
   Update `AudioPlaybackCenterTests` mechanically (test doubles conform instead of
   assigning closures).

5. **Autoplay toggle symmetry** (§2.2, top-10 item 7): route the mini player's autoplay
   toggle through the center (add `AudioPlaybackCenter.setAutoplayEnabled(_:)`/computed
   accessor wrapping `AudioSettings.isAutoplayEnabled`) so the VC layer stops writing
   `AudioSettings` directly, mirroring how `rate` is already brokered. Same underlying
   defaults write, same key, no behavior change.

6. **Small dedups** (§2.3): thumbnail-directory path join (NowPlayingCoordinator +
   MiniPlayerHostViewController) → one shared helper; title-fallback duplicated 2× → one
   helper. Leave the two thumbnail caches alone (different lifetimes; note only).

7. **Doc drift** (§3b): fix `claudedocs/audio-playback.md` — phase-count framing and the
   nonexistent `MiniPlayerTests.swift` reference (actual file:
   `AudioMiniPlayerTests.swift`). Also reflect the dataSource protocol from item 4.

Deferred (do NOT do; report only): extracting the autoplay-chime chain into its own type
(audit item 10) — large and already the best-tested region.

Verification: build-for-testing per commit; at wave end run
`-only-testing:LunaTests/AudioPlaybackCenterTests -only-testing:LunaTests/AudioMiniPlayerTests -only-testing:LunaTests/RSVPAudioResyncTests -only-testing:LunaTests/AudioPlaybackPersistenceTests -only-testing:LunaTests/AudioQueueRuleTests`
(skip `ArticleAudioEngineTests` unless you touched the engine; it may deadlock on this
Mac — CLAUDE.md).
