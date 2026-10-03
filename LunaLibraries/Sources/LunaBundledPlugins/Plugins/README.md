# Bundled plugins

Each `*.js` file here is one plugin Luna ships with, in the shape
`claudedocs/plans/plugin-platform.md` §3 describes: a `luna-plugin` header
comment holding the manifest JSON, then a body that calls `luna.register`.

`BundledPluginCatalog` (LunaPluginKit) enumerates this directory through
`LunaBundledPluginsBundle.bundle`. The NYTimes article plugin fetches on its
trailing-dot hostname and hands the response to Luna's shared article extractor.
The media plugins are here, and `kindle.js` is the first EXPORT plugin: it declares no `produces` and no
`match`, registers only `export`, and takes over the `kindle` destination in
central Luna (`PluginDestinationLegacyIDs`), which is why every article Luna
already sent stays recorded as sent. Luna Reader keeps the Swift destination.

Each media plugin is a port of its Swift twin in `LunaMediaResolve`, which the
Downloader app still runs. `LunaTests/<Platform>PluginTests` runs BOTH engines
over the fixtures in `LunaTests/Fixtures/Plugins/<platform>/` and compares what
they resolved, so a fix to one that is not mirrored fails the suite.

Each media plugin also has a TRANSCRIPT twin, `<platform>-transcript.js`
(`app.luna.<platform>.transcript`, `produces: ["article"]`), that reads the
same URL family as a reader article (`claudedocs/plans/transcription-plugins.md`
§7). Its `ingest` offers the cheapest source of the spoken words, in this
order: captions the site publishes (an `html` Model, no file fetched), an
audio-only file, then the video file — the last two as an `article` Model
with a `transcription` spec Luna downloads, transcribes on device and
deletes. The twins sit at a LOWER priority (90; `direct-media-transcript.js`
at 80, below its `any`-matched twin at 90), and every media plugin's
`classify` returns `false` when the hook input carries `intent:
"transcribe"`, so a plain save still downloads the video, a Transcribe action
reaches the transcript twin, and disabling the media plugin in Settings →
Plugins makes transcribing the platform's default.
`LunaTests/<Platform>TranscriptPluginTests` runs each twin over the same
fixture directory.

No media plugin sets an asset's `headers`: `LiveMediaDownloadManager` already
sends the per-platform User-Agent and Referer those CDNs ask for, and a
plugin's headers would override them.

The folder is deliberately not called `Resources`: a directory by that name at
a bundle's root makes `codesign` read the bundle as a framework layout and
refuse to sign it.
