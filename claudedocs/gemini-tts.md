# Gemini article read-aloud

Luna Reader Settings → Audio has an opt-in **Gemini 3.8 Flash TTS** voice,
using a user-provided Gemini Developer API key from Google AI Studio.
The default remains Apple's device voice. This is separate from Google's
Cloud Text-to-Speech API, which has different billing and quotas.

## Behavior and storage

- Starting an article's read-aloud explicitly may generate its audio. Article
  ingestion, background script refinement, autoplay cache misses, Music's
  readout exports and extensions never start Gemini requests.
- The full spoken article is prepared before playback. Typical English articles
  up to 1,200 words use one request; longer text is split into sequential requests
  of at most 1,200 words and 7,500 UTF-8 bytes, preserving the text. The byte limit
  also bounds text in languages without whitespace. Splits prefer nearby word
  boundaries. The model and voice are fixed to `gemini-3.8-flash-tts` / `Kore`.
- Requests use the documented Interactions REST API, stateless `store: false`,
  an ephemeral URL session, a key header and verbatim transcript text. Keys
  never appear in URLs, defaults, cache filenames or error messages. Google’s
  free-tier data-use terms still apply even with interaction storage disabled.
- The key uses LunaStorage's `CredentialKeychain` primitive (including its
  existing iCloud Keychain behavior), and can be replaced or removed in Audio
  settings. Removing the key disables Gemini; existing audio stays available
  if Gemini is enabled again with a key. The cache itself requires no key.
- AAC files live in Reader's Application Support/GeminiArticleSpeech directory,
  excluded from backups. Identity includes the saved article UUID, text, block
  boundaries, model, voice and cache format. An unchanged article reuses its
  audio across pauses, seeks, replays and app restarts. Edited/refined spoken
  text creates a new cache identity. Audio remains until explicitly deleted,
  its article is removed, or the app is uninstalled.
- Each successful WAV response is compressed to 64 kbps AAC, finalized,
  atomically published and validated before reuse.
  Concurrent requests for an article share generation. A quota/network failure
  pauses playback, reports an actionable error, and never silently skips text
  or marks the article finished. An explicit retry reuses completed chunks.
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
