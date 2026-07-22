# Wave 6C — merge the RSVP preview's playback engine with the full RSVP reader's

User directive: "Merge RSVP preview and full RSVP logic so they're as shared as
possible." This lifts the earlier out-of-scope ruling. Behavior should stay the same for
both surfaces, but this wave is allowed the judgment calls inherent in unification —
where the two implementations differ accidentally (not by design), converge on the
full reader's behavior and note it.

Read first: PLAN.md hard rules 2-6 (rule 1 is relaxed exactly as described above);
refactor-plans/audits/reader-ui.md §2.3(a) (the duplication inventory) and §2.4's
LinkRSVPPreview notes. Then read the CURRENT `RSVPViewController.swift` and
`LinkRSVPPreview.swift` in full — Wave 3A already gave the reader `render(at:)`,
`dispatchOnMode`, `updatePlayPauseGlyph`, `FinishedReadingTracker`, and delegate
protocols; build on those, don't parallel them.

## Shape of the shared core (all in LunaReaderUI unless noted)

1. **`RSVPWordDisplay` (rendering)** — one implementation of the ORP-highlighted word
   rendering (attributed string construction: ORP index math via `RSVPEngine.orpIndex`,
   highlight color, font handling) used by both the reader's word label path and the
   preview's `showCurrentWord()`. If the two currently render with different
   fonts/scales, that stays a caller-supplied style parameter — unify the CONSTRUCTION,
   not the look.

2. **`RSVPPlaybackClock` (timing)** — one word-timer engine owning: schedule-next with
   per-word duration from `RSVPEngine`/WPM, mid-flight WPM rescale
   (`applyTemporaryWPM`/`rescaleRunningInterval` semantics), pause/resume,
   slow-motion/hold factor if both need it (reader-only features stay in the reader),
   and skip via `RSVPEngine.skipTarget`. Delegate protocol (class-bound, weak) for
   word-advanced / reached-end. The reader's Words-mode timer path and the preview's
   `startWordTimer`/`scheduleNext` both become drivers of this clock. The reader's
   Phrases mode and speech/audio-center-driven display are OUT of the clock — they stay
   reader-owned; the clock is the words-mode timer only.

3. **Context window** — one helper computing the ±N-word context text (the preview's
   `updateContext` vs the reader's context-label logic). Window size stays a parameter
   if they differ.

4. **Audio-center sync** — both files map `AudioPlaybackCenter` word events through
   `AudioWordEventTokenMapping` (now backed by `AudioWordIndexing`). Extract the shared
   observer→token→frame update sequence into one helper both adopt.

## Rules

- The preview keeps its own gesture/menu/lock/haptics/entrance-animation code — that's
  genuinely preview-specific. Only playback/render/context/sync logic is shared.
- `LinkRSVPPreviewGesturePolicyTests` must stay green untouched.
- Add unit tests for the extracted pieces: `RSVPPlaybackClock` (schedule/rescale/skip
  with a fake timer or injected clock), `RSVPWordDisplay` (deterministic attributed
  output), context-window helper. This is the safety net the preview never had.
- Run `ReaderScreenTests` + `RSVPAudioResyncTests` + `RSVPEngineTests` +
  `LinkRSVPPreviewGesturePolicyTests` + your new tests at the end; snapshot diffs in
  ReaderScreenTests = you changed the reader's behavior — fix that.
- Where preview behavior accidentally diverges from the reader (e.g. off-by-one in skip
  target, different rescale rounding), converge on the reader's version and list every
  such convergence in your report — these are the only permitted behavior changes.
- Commits: one per shared piece (display / clock / context / sync), each compiling.
