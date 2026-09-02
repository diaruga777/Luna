/* luna-plugin
{
  "id": "app.luna.direct-media",
  "name": "Direct media",
  "version": "1.0.0",
  "api": 1,
  "description": "Saves a URL that is itself an image, GIF, video or audio file.",
  "produces": ["media"],
  "match": { "any": true },
  "priority": 90,
  "capabilities": []
}
*/

// A URL that names a media file needs no platform resolver: the URL IS the
// asset. `match.any` runs this after every host-matched plugin, so a platform's
// own plugin still owns a post page that happens to end in `.mp4`.
//
// The extension table mirrors `DirectMediaURL` (LunaURLClassification), which
// the Swift resolver's first step reads. `DirectMediaPluginTests` pins the two
// tables to each other.

const IMAGE_EXTENSIONS = ["avif", "heic", "heif", "jpeg", "jpg", "png", "webp"];
const VIDEO_EXTENSIONS = ["m4v", "mov", "mp4"];
const AUDIO_EXTENSIONS = ["aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "wav"];

/// The asset type a URL's own file extension names, or null.
///
/// The query and the fragment are excluded, so a signed CDN link such as
/// `clip.mp4?token=…` stays recognizable.
function assetType(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const scheme = String(parsed.protocol || "").toLowerCase().replace(/:$/, "");
    if (scheme !== "http" && scheme !== "https") { return null; }
    const last = String(parsed.pathname || "").split("/").pop() || "";
    const dot = last.lastIndexOf(".");
    if (dot < 0) { return null; }
    const extension = last.slice(dot + 1).toLowerCase();
    if (extension === "gif") { return "gif"; }
    if (IMAGE_EXTENSIONS.indexOf(extension) >= 0) { return "image"; }
    if (VIDEO_EXTENSIONS.indexOf(extension) >= 0) { return "video"; }
    if (AUDIO_EXTENSIONS.indexOf(extension) >= 0) { return "audio"; }
    return null;
}

luna.register({
    classify({ url }) {
        return assetType(url) ? { kind: "media" } : false;
    },

    async ingest({ url }) {
        const type = assetType(url);
        if (!type) { return null; }
        return { kind: "media", assets: [{ url: url, type: type }] };
    },
});
