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
  Ingestion, background script refinement, autoplay misses and extensions never
  start Gemini requests.
- Reader begins playback after the first generated section and prepares the rest
  in the background. Missing later sections wait for their atomic cache files;
  failures pause playback instead of skipping text. Music finishes its standalone
  readout export before enqueueing it. Typical English articles
  up to 1,200 words use one request; longer text is split into sequential requests
  of at most 1,200 words and 7,500 UTF-8 bytes, preserving the text. The byte limit
  also bounds text in languages without whitespace. Splits prefer nearby word
  boundaries. Requests use Gemini's Interactions streaming TTS mode: audio arrives
  as raw 24 kHz mono PCM deltas while the model is speaking, and preparation
  progress advances with the stream. A complete section is converted to AAC and
  cached before playback consumes it. The preferred model and voice are
  `gemini-3.8-flash-tts` / `Kore`; quota exhaustion falls through to
  `gemini-3.1-flash-tts-preview`, then `gemini-2.5-flash-preview-tts`.
- Requests use the documented streaming Interactions REST API, stateless `store: false`,
  an ephemeral URL session, a key header and verbatim transcript text. Keys
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
  boundaries, model, voice and cache format. An unchanged article reuses its
  audio across pauses, seeks, replays, both apps and app restarts. Edited/refined spoken
  text creates a new cache identity. Audio remains until explicitly deleted,
  its article is removed, or the app is uninstalled.
- Each successful streamed section is compressed to 64 kbps AAC, finalized,
  atomically published and validated before reuse.
  Concurrent requests for an article share generation. When all three models
  report quota exhaustion, a network failure pauses playback and reports an
  actionable error; text is never skipped or marked finished. An explicit retry
  reuses completed chunks.
- Every request has a 120-second wall-clock deadline and a matching URLSession
  resource timeout. Pausing during initial preparation cancels that request;
  resuming retries explicitly, retaining completed sections. The mini-player
  shows preparation progress and a persistent failure title. Diagnostics record
  cache hits, request section, HTTP status, byte count, elapsed time and error
  type/code under `gemini-tts`, never the key, article text or raw server errors.
- Autoplay and cold playback restoration only use existing Gemini audio; on a
  miss they use the device voice. There are no speculative cloud requests and
  no automatic network retries after quota errors.
- Google does not supply speech alignment timestamps. Playback preserves every
  generated frame; paragraph seeking/resume uses proportional text offsets
  within each generated chunk. It is approximate and may land mid-sentence.
  Gemini audio emits no word events, so RSVP does not pretend to synchronize
  individual words. Speed control, mini-player, Now Playing, background audio
  and article completion use the existing playback center and engine.
- Delete saved Gemini audio in Audio settings to reclaim storage. Saves changes
  remove cached audio for deleted articles. At 64 kbps, cached audio uses about
  0.48 MB per minute: an 800-word readout at 170 WPM is about 2.3 MB, plus a
  small container overhead. No automatic eviction is used, so later playback
  remains free of synthesis requests until the user deletes its cache. Cloud failures also offer
  **Use Device Voice** for this article without changing the global preference.
  Removing a Music readout deletes only Music's export; Reader's shared generated
  sections remain reusable. Clearing the shared cache from Reader does not remove
  already exported Music episodes.

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

### Converting a project's actual quota to useful article capacity

Let `R` = free requests/day, `M` = requests/minute, `T` = input tokens/minute,
`L` = article words, and `C` = the actual number of chunks produced by Luna.
For ordinary English with roughly six UTF-8 bytes per word including spacing,
`C ≈ ceil(L / 1200)`; long words, other languages or the byte bound can increase it.

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

Google does not provide a request-time remaining-quota lookup, so fallback begins
when a model returns quota exhaustion. Reusing cached audio and generating only
selected articles are practical ways to conserve free allowance; linking billing
raises service limits but is paid. Free-tier capacity, supported regions, account
quotas and provider limits can change; the linked project dashboard is authoritative.

## Sources

Official Google sources checked on 2026-10-28:

- [Gemini Developer API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [Rate limits and project dashboard](https://ai.google.dev/gemini-api/docs/rate-limits)
- [AI Studio project limits](https://aistudio.google.com/rate-limit)
- [Gemini 3.8 Flash TTS model limits](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts)
- [Speech generation REST request and WAV response](https://ai.google.dev/gemini-api/docs/speech-generation)
- [Interactions API response status](https://ai.google.dev/api/interactions-api)

## Follow-up validation (2026-10-28)

60 focused Reader tests passed, including independent-app cache arbitration,
Reader-local cache migration, first-section playback, deadline cancellation,
retry after timeout, pause/resume cancellation, export to Music's AAC format and
localization. Music's focused integration checks cover key-dependent menu
availability, Reader voice preference, explicit Gemini upgrades, reuse, failed
requests, queue order, current-episode protection, removal and sandbox rebasing.
Google synthesis with the user's key has not been exercised from this workspace.
The supplied diagnostic export had no Gemini request records; it did not establish
whether the reported stall was a provider failure, full-article preparation or
playback. New diagnostics separate those states without recording secrets or text.
An existing real-speaker Music playback test failed in this environment when
Core Audio could not start the simulator output device (AQME timeout/-66681);
export, decoding and the focused integration checks run independently of it.
