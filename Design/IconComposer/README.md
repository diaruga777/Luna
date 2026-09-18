# Icon Composer sources

These are the editable Xcode Icon Composer source packages for Luna Reader,
Luna Downloader, Luna Price Tracker, Luna Vault, and Luna Writer. They are not
part of any Xcode target. Apps consume flattened PNG assets in
`SharedIconAssets.xcassets` (Reader, Downloader, Price Tracker) and
`Luna/Assets.xcassets` (Vault, Writer).

Writer reuses Reader's exact moon and curved glass foreground sources, layer
placement, and materials. Its rose tint and original fountain-pen nib distinguish
it from the other apps. Keep the source and all four raster exports in sync.

To export Writer using Xcode 27 Icon Composer:

```sh
"/Applications/Xcode-27.0.0-Beta.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  "Design/IconComposer/Luna Writer.icon" --export-image --output-file /tmp/writer-icon.png \
  --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
swift scripts/export_writer_icon.swift /tmp/writer-icon.png .
```

The export helper makes an opaque 1024-pixel app-icon master and the
96/192/288-pixel images used by `LunaAppIconImage`. It fills only the area outside
the system mask before compositing the Icon Composer render; the moon and glass
remain rendered from the shared artwork.
