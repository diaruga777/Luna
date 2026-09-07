# Transcription (central Luna)

A plugin can hand Luna a recording instead of text. Luna downloads it,
transcribes it on the device, saves the transcript as an ordinary reader
article, and deletes the recording. Plan and decisions:
`claudedocs/plans/transcription-plugins.md`. Plugin authoring:
`docs/plugins/README.md` ("Transcription") and `docs/plugins/api.md`.

## What a plugin returns

An `article` Model has three body sources. `document` wins, then
`transcription`, then `html`:

```ts
interface ArticleTranscriptionSpec {
  url: string;                       // the recording
  type: "audio" | "video";
  audioURL?: string;                 // a separate audio leg; when present ONLY it is fetched
  headers?: Record<string, string>;  // the same allowed names as a media asset
  expiresAt?: number;                // epoch seconds; a stale URL is re-resolved before the fetch
}
```

`html` is optional beside `transcription`. When it is present, its blocks
come first in the article (a post's text, a video's description). `document`
and `transcription` together are a decode error (`conflictingFields`).
Decoder: `ArticleModel` in `LunaModels/Plugin/PluginModel.swift`.

## The ingest intent

`IngestInput.intent` (`IngestIntent.transcribe`) reaches `classify` and
`ingest` as `intent: "transcribe"`; the key is absent otherwise. The seven
media plugins decline when it is set. The seven transcript plugins
(`<platform>-transcript.js`, priority 90, direct-media 80) claim `article`
whether or not it is set, so:

- a plain save runs the media plugin (higher priority);
- a Transcribe action makes the media plugin decline and the transcript
  plugin claim;
- disabling a media plugin in Settings → Plugins makes its transcript
  plugin that platform's default, from every surface.

A transcribe intent that no plugin serves fails with
`SaveFailureReason.noTranscriptSource` in `IngestPipeline.runUnbounded`. It
never falls through to the Swift classifier, so it never becomes a download.
Safari and both extensions never set the intent.

Each transcript plugin picks the cheapest source in order: captions from
the source (an `html` Model, no file), an audio-only file, the video file.
YouTube offers captions and adaptive audio, TikTok captions, Reddit its
audio leg; X, Instagram and Facebook expose only muxed video.

## From Model to article

1. `ArticleModelAdopter` (LunaReaderUI) turns the spec into a
   `TranscriptionRequest` (LunaModels) and answers
   `PluginAdoptedOutcome.transcription`. No network here.
2. `PluginOutcomeMapping` maps it to `Outcome.transcription`, owned by
   `.reader`. Every `Outcome` switch handles the case.
3. `SavesIngestor.parkTranscription` sets the save's title, leaves it
   `.pending`, and writes a `transcriptions` row (schema 14, `save_id`
   primary key, `ON DELETE CASCADE`, `TranscriptionJobStore` in
   LunaStorage). In the share and action extensions the row is written the
   same way; the app finishes it.
4. `SavesIngestor.ingest` and `ingestAllPending` skip any save with a row.
   The launch sweep would otherwise re-walk a transcribing save, queue a
   second job, or re-walk a failed one WITHOUT its intent and turn it into a
   media save.
5. `TranscriptionJobRunner` (LunaTranscribe, `@MainActor`, central Luna)
   drains rows one at a time inside a UIKit background lease:
   - `unsupportedOS` engine → terminal failure before any download;
   - an expired request, or a fetch answered 401/403/410, is re-resolved
     ONCE through `PluginTranscriptionSeams.reresolver`
     (`PluginTranscriptionReresolver`, installed by
     `PluginPlatformComposition`): a fresh request replaces the row's, an
     `html` Model (captions appeared) is persisted directly;
   - `URLSessionTranscriptionDownloader` fetches `audioURL ?? url` under a
     2 GiB ceiling to `<AppGroup>/Transcriptions/<save-id>.<ext>`, with
     the row's `scratch_path` written first;
   - `SpeechAnalyzerFileTranscriber` decodes the audio track with
     `AudioTrackReader` (`AVAssetReader`, first audio track only) and runs
     `SpeechAnalyzer` + `SpeechTranscriber` with `.audioTimeRange`
     attributes; `TranscriptArticleBuilder` groups final results into
     paragraphs (a gap of 2 s or more, or 90 words at a sentence end);
   - `IngestorKindHandlers.article.persistArticle` writes the article,
     which is the ONLY transition out of `.pending`; then `markDone`.
   The recording is unlinked after every outcome, and
   `TranscriptionScratchSweep` removes any file at launch whose row is not
   `downloading` or `transcribing`.
6. Failures: `TranscriptionError.isTerminal` (unsupported OS or language,
   no audio track, no speech, too large, undecodable) or three attempts
   (`TranscriptionRetryPolicy`, backoff `min(2^attempts, 60)` minutes) mark
   the save `.failed` with `SaveFailureReason.transcriptionFailed(detail)`.
   The row stays as `failed` so the sweep keeps skipping the save; deleting
   the save cascades it. Both transcription reasons are not rescuable and
   not retried by the launch sweep.

Every step records `SaveDiagnostics` under the `transcription` category.

## In the app

`TranscriptionShellWiring` (`Luna/`, excluded from the three sibling apps
by membership exception) installs the lease and `PendingSaveStatus
.provider`, sweeps and kicks at launch, and kicks on foreground and on every
saves change. `PendingSaveCardContentViewController` shows the job's step
("Waiting to transcribe…", "Downloading audio…", "Transcribing…") in place
of the loading line.

Two affordances, offered only when `LunaApp.current.transcribesMedia` (the
central app) on iOS 26: a long press on the util card's paste row ("Paste &
Transcribe") and a "Transcribe" item in a media card's menu. Both go through
`TranscribeSaveAction`: `SavesStore.addSeparate` inserts a NEW save for the
URL (`add` and `reserveSaveAttempt` both answer the existing row) and
`SavesIngestor.ingest(item, intent: .transcribe)` runs the walk. The media
save is untouched.

## Tests

`TranscriptionJobRunnerTests` (stubbed downloader, engine, re-resolver and
lease over a real store), `AudioTrackReaderTests` (containers written at
test time), `SpeechAnalyzerFileTranscriberTests` (gated on
`RUN_SPEECH_TRANSCRIBER_TESTS=1`; the simulator has no speech model),
`TranscriptionJobStoreTests`, `TranscriptArticleBuilderTests`,
`SavesIngestorTranscriptionTests` (the sweep exemption),
`IngestIntentPipelineTests`, `PluginTranscriptionReresolverTests`,
`PendingSaveCardContentViewControllerTests`, and the seven
`<Platform>TranscriptPluginTests` over `LunaTests/Fixtures/Plugins/`.

## Out of scope

Keeping the video AND a transcript from one save, tap-to-seek timestamps,
live captions during playback, streaming transcription of fragmented MP4,
WhisperKit, and the Reader app accepting video.
