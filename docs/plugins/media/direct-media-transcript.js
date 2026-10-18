/* luna-plugin
{
  "id": "app.luna.direct-media.transcript",
  "name": "Direct media transcript",
  "version": "1.0.0",
  "api": 1,
  "description": "Reads a URL that is itself an audio or video file as a transcript article.",
  "produces": ["article"],
  "match": { "any": true },
  "priority": 80,
  "capabilities": []
}
*/

// The transcript twin of `direct-media.js`. A URL that names an audio or
// video file needs no resolution: the URL IS the transcription source. Images
// and GIFs carry no speech and are declined. `match.any` runs this after
// every host-matched plugin; `direct-media.js` (priority 90) outranks it and
// declines a transcribe intent.
//
// The extension table mirrors `direct-media.js`, whose own test pins it to
// `DirectMediaURL` (LunaURLClassification).

const VIDEO_EXTENSIONS = ["m4v", "mov", "mp4"];
const AUDIO_EXTENSIONS = ["aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "wav"];

/// `{ type, name }` for a URL whose path names an audio or video file, else null.
function source(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const scheme = String(parsed.protocol || "").toLowerCase().replace(/:$/, "");
    if (scheme !== "http" && scheme !== "https") { return null; }
    const last = String(parsed.pathname || "").split("/").pop() || "";
    const dot = last.lastIndexOf(".");
    if (dot < 0) { return null; }
    const extension = last.slice(dot + 1).toLowerCase();
    let name = last;
    try {
        name = decodeURIComponent(last);
    } catch (error) {
        // A name that is not percent-encoded is shown as written.
    }
    if (VIDEO_EXTENSIONS.indexOf(extension) >= 0) { return { type: "video", name: name }; }
    if (AUDIO_EXTENSIONS.indexOf(extension) >= 0) { return { type: "audio", name: name }; }
    return null;
}

luna.register({
    classify({ url }) {
        return source(url) ? { kind: "article" } : false;
    },

    async ingest({ url }) {
        const file = source(url);
        if (!file) { return null; }
        return {
            kind: "article",
            title: file.name.slice(0, 300),
            transcription: { url: url, type: file.type },
        };
    },
});
