# Gemini article read-aloud

Luna Reader Settings → Audio has an opt-in **Gemini 3.8 Flash TTS** voice,
using a user-provided Gemini Developer API key from Google AI Studio.
The default remains Apple's device voice. This is separate from Google's
Cloud Text-to-Speech API, which has different billing and quotas.

## Behavior and storage

- Starting an article's read-aloud explicitly may generate its audio. Music's
  Reader-article browser can also generate a readout using Reader's saved key:
  normal adds follow Reader's voice preference; **Add with Gemini** and
  **Play Next with Gemini** explicitly select Gemini whenever a key is available.
  Reader also schedules nightly pre-generation for unread articles when this
  voice is enabled and a key is saved (see below). Ingestion, background script
  refinement, autoplay misses and extensions never start Gemini requests.
- New audio chooses a voice from the extracted article byline: likely male
  → **Charon**, likely female → **Kore**. Explicit he/him or she/her pronouns
  take precedence; they/them keeps Kore. A bundled given-name lookup makes the
  usual case immediate, free and fully offline, including without Apple
  Intelligence. The table aggregates SSA national name counts (1880–2020),
  requiring 1,000 occurrences and at least 95% of one recorded sex. Statistically
  ambiguous names retain Kore. This is a rough, US-biased name association,
  not verified identity; it can be wrong across cultures and for individual authors.
  Organizations, multiple authors, initials and unusable bylines keep Kore.
  Unfamiliar names may use Apple's on-device Foundation Models framework with
  a three-second budget. Refusals/errors/unavailability keep Kore. Local model
  checks returned unknown for common names and refused a more direct prompt,
  which is why the table is primary. No extra cloud requests or lookup service.
  Classification runs when audio is generated, never during cache-only autoplay.
  Nightly preparation uses only the offline lookup and never starts Apple's model.
  A hashed-byline sidecar stores only the selected voice inside the article's
  shared cache folder, under the same cross-process lock. Reader and Music reuse
  that choice for every section, retry and model fallback, even without Apple
  Intelligence. Clearing the audio cache also clears voice choices. Completed Kore audio with the same chunk plan stays reusable; delete it to apply matching to that article.
  Regenerate the table with `scripts/build_author_voice_names.py` from SSA's
  national ZIP (CC0), or `name,sex,count,year` records. The bundled input is the
  [SSA data mirror](https://github.com/hackerb9/ssa-baby-names/blob/main/alldata.txt);
  input SHA-256, coverage years and thresholds are recorded in the resource header.
  Only the federal statistical data is used, with no mirror code dependency.
  [SSA source and license](https://catalog.data.gov/dataset/baby-names-from-social-security-card-applications-national-data).

- Reader begins playback from the first streamed PCM buffers, before the first
  request finishes, and prepares the rest in the background. A pull renderer
  supplies at most one second at a time through the existing engine's bounded
  lookahead; temporary disk spools keep a whole article out of memory. Seeking
  waits for the relevant chunk's final duration before applying proportional text
  offsets. Stream failures pause playback instead of skipping text or marking
  the save finished. Music finishes its standalone
  readout export before enqueueing it. Typical English articles
  up to 1,200 words use one request; longer text is split into sequential requests
  targeting 1,200 words and 7,500 UTF-8 bytes. Natural Language sentence ranges
  partition the original text exactly once, including separators, quotes and
  scripts without whitespace. Every split is a sentence or paragraph end;
  requests never repeat a previous chunk's words as context. An indivisible
  sentence exceeding either target stays whole, so unusually long sentences can
  exceed those targets and may be rejected by the provider. The selected voice stays fixed across sections and models. Models fall back in order:
  `gemini-3.8-flash-tts`, `gemini-3.1-flash-tts-preview`, then
  `gemini-2.5-flash-preview-tts`. A quota or unavailable-model response advances
  to the next model for the remaining chunks; authentication, transport and
  malformed-audio failures do not spend another model's allowance.
- Gemini 3.8/3.1 use the documented Interactions REST API with `stream: true`,
  raw 24 kHz mono signed little-endian 16-bit PCM and stateless `store: false`.
  The non-streaming 2.5 fallback uses its documented GenerateContent endpoint
  and normalizes its completed audio into the same PCM/cache pipeline.
  Requests use an ephemeral URL session, a key header and the article transcript.
  Older models receive an explicit synthesis preamble; 3.8 receives verbatim text. Keys
  never appear in URLs, defaults, cache filenames or error messages. Google’s
  free-tier data-use terms still apply even with interaction storage disabled.
- The key uses LunaStorage's `CredentialKeychain` primitive (including its
  existing iCloud Keychain behavior), and can be replaced or removed in Audio
  settings. Removing the key disables Gemini; existing audio stays available
  if Gemini is enabled again with a key. The cache itself requires no key.
- AAC sections live in the App Group's GeminiArticleSpeech directory, excluded
  from backups and shared between Reader and Music. Existing Reader-local cache
  entries migrate on first access without another request. A process-wide actor
  and a cross-process advisory file lock prevent duplicate API work. Identity includes the saved article UUID, text, block
  boundaries, primary model, voice, cache format and the actual chunk ranges.
  Bounded single-chunk readouts retain their v2 identity because the request
  text and range are unchanged, preserving already-paid audio. Split/oversized
  readouts use v3 sentence identities; previous v2 word-split boundaries cannot
  safely be reused with the new plan. Old entries remain subject to retention
  and deletion. An unchanged article reuses its
  audio across pauses, seeks, replays, both apps and app restarts. Edited/refined spoken
  text creates a new cache identity. Each audio chunk expires 14 days after
  generation while its article is unread (including opened-but-unfinished), or
  2 days after generation if the article is read. Becoming read shortens the
  lifetime; it does not restart the generation clock. Playback/cache hits never
  refresh that clock. Legacy migration preserves original chunk timestamps.
  Reader prunes expired/deleted audio at launch, foreground, saves changes and
  nightly background runs, under the same cross-process lock as generation.
  Cleanup is opportunistic when iOS allows the app to run. Explicit deletion,
  removing the article and uninstalling also remove audio.
- SSE framing handles metadata, multiline events and UTF-8 lines. Replayed
  event IDs are consumed once; a conflicting payload for the same ID fails
  rather than appending duplicate PCM. Identical audio under different IDs is
  preserved (silence and repeated samples are valid). Audio format,
  base64 and an explicit successful terminal status are required; closing the
  socket alone never publishes a cache entry. Valid completed PCM is compressed
  to 64 kbps AAC, finalized, atomically published and validated before reuse.
  Temporary playback spools are removed with the generation/renderer lifetime.
  Every received PCM delta is also appended to a durable `.partial.pcm` file in
  the same cache before it becomes available for playback. An atomic
  `.partial.json` manifest records confirmed sentence text/frame checkpoints.
  These files survive transport errors, quota exhaustion, malformed terminal
  events, deadlines, cancellation and process termination. They never count as
  completed readouts or exports. Successful AAC publication removes that chunk's
  partial files. Partial PCM uses the same read/unread retention window as AAC,
  measured from its last received audio. Concurrent requests share generation.
  Exhausting every model or a network failure pauses playback, reports an
  actionable error, and never silently skips text or marks the article finished.
  An explicit retry reuses completed chunks and recovers interrupted audio:
  installed on-device SpeechTranscriber models align the unfinished stream to
  the exact input prefix, retaining audio only through the last confirmed full
  sentence and requesting only the remaining suffix. The incomplete final
  sentence is regenerated. Subsequent failures retain all earlier confirmed
  prefixes. No WPM estimate is used to drop text. Recovery does not download
  speech assets or use another cloud service. If the device/language has no
  installed model, alignment times out (30 seconds), or words do not match,
  recovery falls back to the previous confirmed sentence or complete chunk.
- Every request has a 120-second wall-clock deadline and a matching URLSession
  resource timeout. Pausing during initial preparation cancels that request;
  resuming retries explicitly, retaining completed sections. The mini-player
  shows incremental generation progress even after playback starts, and a
  persistent failure title. Within-chunk percentages estimate duration at 170 WPM
  because Google sends no final byte count; they remain below 100% until validated.
  Diagnostics record cache hits, request section, selected model, fallback,
  byte count, elapsed time and error
  type/code under `gemini-tts`, never the key, article text or raw server errors.
- Autoplay and cold playback restoration only use existing Gemini audio; on a
  miss they use the device voice. There are no speculative cloud requests and
  no automatic retries of the same exhausted model. Fallback occurs before any
  audio from the failed request; a quota error after PCM arrives pauses instead
  of restarting the chunk and potentially repeating words already heard.
- Google does not supply speech alignment timestamps. Playback preserves every
  generated frame exactly once. After a stream failure, the renderer hands the
  audible chunk/frame position (excluding queued lookahead) to its replacement,
  which resumes at the previous confirmed sentence. Completed cached sections
  can be aligned on device for the same recovery; absent reliable timing, their
  sentence-aligned start is the safe fallback. Ordinary paragraph seeking and
  cold restoration still use approximate proportional text offsets.
  Gemini audio emits no word events, so RSVP does not pretend to synchronize
  individual words. Speed control, mini-player, Now Playing, background audio
  and article completion use the existing playback center and engine.
- Delete saved Gemini audio in Audio settings to reclaim storage. Saves changes
  remove cached audio for deleted articles. At 64 kbps, cached audio uses about
  0.48 MB per minute: an 800-word readout at 170 WPM is about 2.3 MB, plus a
  small container overhead. Replaying retained audio uses no synthesis quota.
  Cloud failures also offer
  **Use Device Voice** for this article without changing the global preference.
  Removing a Music readout deletes only Music's export; Reader's shared generated
  sections remain reusable. Clearing the shared cache from Reader does not remove
  already exported Music episodes.

## Nightly unread-article audio

Reader registers `com.hsanabria.luna.nightlyArticleAudio` before launch returns,
permits it in Info.plist, and submits a network-enabled `BGProcessingTaskRequest`
at launch/background (and when configuring Gemini). Existing pending requests
are preserved. No external-power requirement is imposed. The request's earliest
begin date is 23:00 **fixed PST (UTC−8)**, independent of device timezone and
of daylight saving time. This is literal PST, rather than `America/Los_Angeles`:
during PDT the requested window corresponds to midnight–1am Los Angeles time.
Google documents its quota reset as midnight Pacific time; its reset and this
explicitly requested fixed-PST window can therefore differ during DST.

BGTaskScheduler does not guarantee a launch within an hour or on every day.
An early/late launch exits without synthesis and queues the next eligible
23:00 window. An in-window launch queues the following night before starting
work. A midnight watchdog and per-request deadline cancel in-flight work;
the renderer checks the window again after obtaining the cross-process lock,
before every chunk/model request, for incoming PCM and before publishing audio.
A response already sent to Google cannot be recalled by cancellation.

Only ready, readable, unfinished articles are eligible, newest **dateAdded**
first regardless of manual list order or bump dates. Read/deleted state and the
Gemini voice/key opt-in are rechecked as the job advances. The job uses cached
trim scripts (or a heuristic script on a miss) without starting an on-device LLM.
Current-identity complete audio is reused, partial audio resumes at missing
chunks, and concurrent foreground generation is left alone. The first quota,
authentication, transport, invalid-audio or model error exits the whole job:
**no nightly model fallback or quota retry**. Completed chunks remain cached.
Normal explicit foreground playback keeps its existing model fallback behavior.
Expiration cancels work and completes the BG task; the next request is already
queued. There is no out-of-window foreground catch-up or live quota probe.

## Free allowance: evaluated 2026-10-28

Google lists standard Gemini 3.8 Flash TTS input and output as **free of charge**
on the Gemini Developer API free tier. A key alone does not establish that the
project is on the free tier; a billed project's requests can incur charges.
The UI explains that article text goes to Google and that free-tier content
may be used to improve Google's products.

**There is no currently published, universal free RPM/TPM/RPD number.** Google's
rate-limit documentation directs users to their project's live AI Studio
limits, explicitly says capacity is not guaranteed, and applies quotas per
project rather than per key. Multiple keys do not multiply the allowance.
Daily request quotas reset at midnight Pacific time. A Gemini consumer
subscription is not a quota assumption used by this feature.


Google does not provide a reliable remaining-quota counter in these synthesis
responses. Luna reacts to `429`/`RESOURCE_EXHAUSTED` rather than inventing a
balance. Model cooldowns are credential-specific and held in memory: honor
`Retry-After` or structured `RetryInfo`, use the next Pacific midnight for a
reported daily quota, otherwise wait 60 seconds before trying that model again.
A missing model is skipped for one hour. Replacing a key does not inherit the
old key's cooldown (but Google's underlying quota still belongs to the project).

For additional free listening, keep generated audio cached or use Apple's
on-device voice. Gemini 3.8 Flash-Lite TTS is another possible future fallback
if the project's AI Studio dashboard shows a separate free allocation; it is
not inserted into the requested model order. Extra keys in the same project do
not add quota. No account/project rotation is implemented.

### Converting a project's actual quota to useful article capacity

Let `R` = free requests/day, `M` = requests/minute, `T` = input tokens/minute,
`L` = article words, and `C` = the actual number of chunks produced by Luna.
For ordinary English with roughly six UTF-8 bytes per word including spacing,
`C ≈ ceil(L / 1200)`; sentence boundaries, long words, other languages or the
byte target can increase it.

- Complete articles/day: `floor(R / C)`.
- Words/day for equal-length articles: `L × floor(R / C)`.
- Article requests/minute: at most `min(M, T / inputTokensPerChunk)`, subject
  also to the remaining daily allowance and provider capacity.
- Article generation throughput/minute: that request budget divided by `C`.
  Luna generates sequentially, so actual wall-clock throughput can be lower.
- Listening time: `words / 170` minutes at an assumed natural 170 WPM.
  Listening speed can be changed locally without using quota.

Using a 600–1,000-word news article as an explicit planning range (not a claim
that every publisher has the same typical length):

| Article words | Requests/article in ordinary English | Listening/article at 170 WPM | Complete articles per 10 daily requests | New words per 10 daily requests |
| --- | --- | --- | --- | --- |
| 600 | 1 | 3.5 min | 10 | 6,000 |
| 800 | 1 | 4.7 min | 10 | 8,000 |
| 1,000 | 1 | 5.9 min | 10 | 10,000 |
| 1,200 | 1 | 7.1 min | 10 | 12,000 |

**The 10-request column is a conversion example, not a verified account quota.**
For example, *if* a project shows 10 requests/day and 3 requests/minute, and
input-token quota is sufficient, an 800-word workload provides up to 10 new
articles / 8,000 words / 47 minutes of audio per day (about 300 articles /
240,000 words / 23.5 listening hours in a 30-day month). The minute-level
request budget could admit three such articles / 2,400 words / 14.1 listening
minutes of new audio per minute until the daily budget is exhausted. This
is quota math, not measured generation latency. Longer articles consume
multiple daily requests. Replaying any cached article consumes **zero**
requests and has no daily listening limit.

The model's 16,384 output-token serving limit at 25 audio tokens/second is
655.36 seconds, or about 10.9 minutes per request. At an assumed 150–170 WPM,
that is roughly 1,638–1,857 words of theoretical audio output. Luna's smaller
1,200-word chunks leave room for slower delivery and pauses and stay within
the 8,192 input-token limit with the byte bound; they do not promise that every
request will succeed. Incomplete responses are rejected rather than cached as
complete readouts. Free-tier capacity, supported regions, account quotas and
provider limits can change; the linked project dashboard is authoritative.

## Sources

Official Google sources checked on 2026-10-28:

- [Gemini Developer API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [Rate limits and project dashboard](https://ai.google.dev/gemini-api/docs/rate-limits)
- [AI Studio project limits](https://aistudio.google.com/rate-limit)
- [Gemini 3.8 Flash TTS model limits](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts)
- [Speech generation REST request and WAV response](https://ai.google.dev/gemini-api/docs/speech-generation)
- [Interactions API response status](https://ai.google.dev/api/interactions-api)
- [Google voice names and genders](https://firebase.google.com/docs/ai-logic/generate-speech#voices)
- [Apple on-device SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

## Streaming replacement validation (2026-10-28)

Focused simulator coverage exercises early PCM playback before request completion,
odd-byte delta boundaries, exact frame totals, cache-only replay, migration,
SSE terminal/error validation, ranked quota fallback, per-credential cooldowns,
Pacific-day resets, cancellation, deadlines, export and playback-center completion.
Music coverage checks filtering, the bundled Reader icon and cell reuse, source
completion, deleted-source handling, queue ordering, reuse and real readout playback.
Live Google synthesis with the user's credential has not been exercised.

## Sentence recovery validation (2026-10-29)

Simulator regressions cover disjoint/lossless sentence ranges, abbreviations,
quotes, emoji and unspaced scripts; indivisible oversized sentences; repeated
network/quota failures across new provider instances; exact retained-frame and
remaining-transcript totals; odd-byte interruption; cancellation/deadline
persistence; unavailable/mismatched alignment; audible-frame retry handoff;
and SSE replay deduplication. Recovery timing is injected in these tests;
installed-device SpeechTranscriber and live Google synthesis have not been
exercised. Speech timing APIs follow [Apple's SpeechAnalyzer documentation](https://developer.apple.com/documentation/speech/speechanalyzer);
Gemini audio/event fields follow the [Interactions API reference](https://ai.google.dev/api/interactions-api).
