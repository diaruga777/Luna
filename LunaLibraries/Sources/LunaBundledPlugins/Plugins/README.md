# Bundled plugins

Each `*.js` file here is one plugin Luna ships with, in the shape
`claudedocs/plans/plugin-platform.md` §3 describes: a `luna-plugin` header
comment holding the manifest JSON, then a body that calls `luna.register`.

`BundledPluginCatalog` (LunaPluginKit) enumerates this directory through
`LunaBundledPluginsBundle.bundle`. Waves 2 and 3 add the media, Kindle and
Xteink plugins.

The folder is deliberately not called `Resources`: a directory by that name at
a bundle's root makes `codesign` read the bundle as a framework layout and
refuse to sign it.
