# Bundled plugins

Each `*.js` file here is one plugin Luna ships with, in the shape
`claudedocs/plans/plugin-platform.md` §3 describes: a `luna-plugin` header
comment holding the manifest JSON, then a body that calls `luna.register`.

`BundledPluginCatalog` (LunaPluginKit) enumerates this directory through
`LunaBundledPluginsBundle.bundle`. The seven media plugins are here; Wave 3
adds the Kindle and Xteink export plugins.

Each media plugin is a port of its Swift twin in `LunaMediaResolve`, which the
Downloader app still runs. `LunaTests/<Platform>PluginTests` runs BOTH engines
over the fixtures in `LunaTests/Fixtures/Plugins/<platform>/` and compares what
they resolved, so a fix to one that is not mirrored fails the suite.

No media plugin sets an asset's `headers`: `LiveMediaDownloadManager` already
sends the per-platform User-Agent and Referer those CDNs ask for, and a
plugin's headers would override them.

The folder is deliberately not called `Resources`: a directory by that name at
a bundle's root makes `codesign` read the bundle as a framework layout and
refuse to sign it.
