# Luna Reader

Luna Reader is the former Luna Core app. It remains the single link app and
accepts articles, documents, media, social posts, and products. The former
standalone Reader, Shopping/Price Tracker, and Downloader apps are retired.

- Phone name: **Luna Reader**.
- Xcode target and scheme: `LunaReader`; built product: `LunaReader.app`.
- Bundle ID: `com.hsanabria.luna` (unchanged).
- App Store listing: **Luna: Save Anything**, app ID `6800900997` (unchanged).
- Swift app module: `Luna`, so existing app-hosted tests keep their imports.

The `Luna/` source folder, `LunaKit`, `LunaShare`, `LunaAction`, `LunaSafari`,
and `LunaLiveActivity` belong to this app. Reader UI, media downloads, and price
tracking remain features; removing the former standalone apps does not remove
those features.

`LunaApp.luna`, `_Core` localization suffixes, defaults keys, URL schemes,
App Group and iCloud IDs, and the `.luna`/`.lunar`/`.lunad`/`.lunas` file types
remain stable for existing saves, shortcuts, imports, and extensions. The enum's
retired `.reader`, `.downloader`, and `.priceTracker` cases describe legacy data
and feature examples; they are not shipping app targets. Their displayed app
name and app artwork resolve to the surviving Luna Reader.

The bundled **Luna Reader** shortcut targets the unchanged bundle ID. The
handmade Action extension artwork is preserved in `ReaderActionExtIcon`.
