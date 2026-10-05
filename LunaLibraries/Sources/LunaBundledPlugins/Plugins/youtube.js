/* luna-plugin
{
  "id": "app.luna.youtube",
  "name": "YouTube",
  "version": "1.0.1",
  "api": 1,
  "description": "Resolves a YouTube video, Short or clip to a progressive MP4 with sound.",
  "produces": ["media"],
  "match": {
    "hosts": [
      "youtube.com", "*.youtube.com", "youtu.be",
      "youtube-nocookie.com", "*.youtube-nocookie.com"
    ]
  },
  "priority": 100,
  "capabilities": ["fetch"]
}
*/

// The mobile watch page advertises an `MWEB` progressive MP4, but Google's video
// servers reject that URL without a Proof-of-Origin token. The maintained
// no-token fallback is an ANDROID_VR player request, and it needs two things the
// watch page holds: the guest visitor session, and the signature timestamp of
// the player JavaScript that page is currently serving. So the ladder is:
//
//   watch page  →  VISITOR_DATA + the player's jsUrl
//   player JS   →  signatureTimestamp
//   ANDROID_VR player  →  direct HTTPS formats
//
// Every request runs on the shared cookie jar, which is what binds the guest
// session across the three calls.
//
// Adaptive video-only and audio-only streams are deliberately excluded: the
// durable download engine is single-file and resumable, and returning a
// video-only stream would silently lose the sound.

/// yt-dlp's current no-token player fallback. Versions newer than 1.65 can
/// return SABR-only responses, so this exact client and version pairing stays.
const ANDROID_VR_CLIENT_VERSION = "1.65.10";
const ANDROID_VR_USER_AGENT =
    "com.google.android.apps.youtube.vr.oculus/1.65.10 "
    + "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
const WEB_SAFARI_USER_AGENT =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)";
/// Avoids the consent interstitial while the guest VISITOR/YSC cookies the
/// response sets are still retained.
const CONSENT_COOKIE = "PREF=hl=en&tz=UTC; SOCS=CAI";

const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;
const ID_PATH_KINDS = ["shorts", "live", "embed", "v"];

async function getText(request) {
    try {
        const response = await luna.fetch(request);
        if (!response.ok || typeof response.text !== "string") { return null; }
        return response.text;
    } catch (error) {
        return null;
    }
}

function htmlRequest(url) {
    return {
        url: url,
        timeout: 30,
        headers: {
            "User-Agent": WEB_SAFARI_USER_AGENT,
            Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-us,en;q=0.5",
            Cookie: CONSENT_COOKIE,
        },
    };
}

// MARK: - The URL family

/// Plain seconds, plus YouTube's `1h2m3s`, `2m10s` and `90s` forms.
function seconds(raw) {
    const value = String(raw || "").toLowerCase().trim();
    const plain = Number(value);
    if (value.length > 0 && !isNaN(plain) && plain >= 0) { return plain; }
    const match = /^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m)?(?:(\d+(?:\.\d+)?)s)?$/.exec(value);
    if (!match || match[0].length !== value.length) { return null; }
    function part(index) {
        return match[index] === undefined ? 0 : Number(match[index]);
    }
    const total = part(1) * 3600 + part(2) * 60 + part(3);
    return total > 0 ? total : null;
}

function videoIDOf(parsed) {
    function valid(value) {
        return (typeof value === "string" && VIDEO_ID_PATTERN.test(value)) ? value : null;
    }
    const parts = String(parsed.pathname || "").split("/").filter(function (part) {
        return part.length > 0;
    });
    if (parsed.hostname === "youtu.be") { return valid(parts[0]); }
    const query = valid(parsed.searchParams.get("v"));
    if (query) { return query; }
    if (parts.length > 1 && ID_PATH_KINDS.indexOf(parts[0]) >= 0) { return valid(parts[1]); }
    return null;
}

/// The clip range a URL asks for, as `{ start, end }` seconds, or null when it
/// asks for none. `end` is 0 for a start-only link: the core reads an end that
/// is not past the start as "to the source end".
function timeRangeOf(parsed) {
    const hash = String(parsed.hash || "").replace(/^#/, "");
    const fragment = hash.indexOf("t=") === 0 ? hash.slice(2) : hash;
    // Each source is read in turn and the FIRST that parses wins, including a
    // zero: `?start=0&t=90` starts at zero, not ninety.
    const sources = [
        parsed.searchParams.get("start"),
        parsed.searchParams.get("t"),
        hash.length > 0 ? fragment : null,
    ];
    let start = 0;
    for (let i = 0; i < sources.length; i++) {
        if (sources[i] === null) { continue; }
        const parsedStart = seconds(sources[i]);
        if (parsedStart !== null) { start = parsedStart; break; }
    }
    const rawEnd = parsed.searchParams.get("end");
    const end = rawEnd !== null ? seconds(rawEnd) : null;
    if (start <= 0 && end === null) { return null; }
    return { start: start, end: end === null ? 0 : end };
}

function isClip(parsed) {
    const parts = String(parsed.pathname || "").split("/").filter(function (part) {
        return part.length > 0;
    });
    return String(parts[0] || "").toLowerCase() === "clip";
}

// MARK: - Reading the pages

function firstGroup(text, pattern) {
    const match = pattern.exec(text);
    return (match && match[1]) ? match[1] : null;
}

function decodeJSONString(literal) {
    try {
        const value = JSON.parse(literal);
        return typeof value === "string" ? value : null;
    } catch (error) {
        return null;
    }
}

/// The underlying video and range a `/clip/<id>` page names.
function clipDescriptor(html) {
    const marker = html.indexOf("clipConfig");
    const search = marker < 0 ? html : html.slice(marker, marker + 8000);
    const normalized = search.split("\\\"").join("\"");
    const videoID = firstGroup(normalized, /"videoId"\s*:\s*"([A-Za-z0-9_-]{11})"/);
    const startRaw = firstGroup(normalized, /"startTimeMs"\s*:\s*"?(\d+)"?/);
    const endRaw = firstGroup(normalized, /"endTimeMs"\s*:\s*"?(\d+)"?/);
    if (!videoID || !startRaw || !endRaw) { return null; }
    const start = Number(startRaw) / 1000;
    const end = Number(endRaw) / 1000;
    if (!(end > start)) { return null; }
    return { videoID: videoID, timeRange: { start: start, end: end } };
}

/// The guest session the ANDROID_VR request must carry, and the player script
/// whose signature timestamp it must quote.
function bootstrap(html) {
    const visitorLiteral = firstGroup(html, /"VISITOR_DATA"\s*:\s*("(?:\\.|[^"\\])*")/);
    const playerLiteral = firstGroup(html, /"(?:jsUrl|PLAYER_JS_URL)"\s*:\s*("(?:\\.|[^"\\])*")/);
    const visitor = visitorLiteral ? decodeJSONString(visitorLiteral) : null;
    const playerPath = playerLiteral ? decodeJSONString(playerLiteral) : null;
    if (!visitor || !playerPath) { return null; }
    const playerURL = luna.parseURL(playerPath, "https://www.youtube.com");
    if (!playerURL) { return null; }
    let visitorData = visitor;
    try {
        visitorData = decodeURIComponent(visitor);
    } catch (error) {
        // A visitor blob that is not percent-encoded travels as written.
    }
    return { visitorData: visitorData, playerJavaScriptURL: playerURL.href };
}

function signatureTimestamp(source) {
    const raw = firstGroup(source, /(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})/);
    return raw ? Number(raw) : null;
}

// MARK: - The player response

/// The object at `start`, read to its balanced closing brace.
function balancedObject(text, start) {
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let index = start; index < text.length; index++) {
        const character = text.charAt(index);
        if (inString) {
            if (escaped) {
                escaped = false;
            } else if (character === "\\") {
                escaped = true;
            } else if (character === "\"") {
                inString = false;
            }
        } else if (character === "\"") {
            inString = true;
        } else if (character === "{") {
            depth += 1;
        } else if (character === "}") {
            depth -= 1;
            if (depth === 0) { return text.slice(start, index + 1); }
        }
    }
    return null;
}

/// The player response in `text`: the whole body when it is the JSON answer,
/// else the `ytInitialPlayerResponse` a page assigned.
///
/// A page commonly emits `var ytInitialPlayerResponse = null` before the real
/// assignment, so every occurrence is walked and only a value whose first
/// non-whitespace character is `{` is accepted.
function playerResponse(text) {
    try {
        const object = JSON.parse(text);
        if (object && object.streamingData) { return object; }
    } catch (error) {
        // Not the JSON answer; read the page instead.
    }
    let cursor = 0;
    while (true) {
        const found = text.indexOf("ytInitialPlayerResponse", cursor);
        if (found < 0) { return null; }
        cursor = found + "ytInitialPlayerResponse".length;
        const equals = text.indexOf("=", cursor);
        if (equals < 0) { return null; }
        let valueStart = equals + 1;
        while (valueStart < text.length && /\s/.test(text.charAt(valueStart))) {
            valueStart += 1;
        }
        if (text.charAt(valueStart) !== "{") { continue; }
        const json = balancedObject(text, valueStart);
        if (!json) { continue; }
        try {
            const object = JSON.parse(json);
            if (object && object.streamingData) { return object; }
        } catch (error) {
            // Not the player response; keep walking.
        }
    }
}

function integer(value) {
    if (typeof value === "number") { return value; }
    if (typeof value === "string") {
        const parsed = Number(value);
        return isNaN(parsed) ? null : parsed;
    }
    return null;
}

function bestThumbnail(response, videoID) {
    const details = response.videoDetails || {};
    const list = (details.thumbnail && details.thumbnail.thumbnails) || [];
    for (let i = list.length - 1; i >= 0; i--) {
        if (typeof list[i].url === "string" && list[i].url.length > 0) { return list[i].url; }
    }
    return "https://i.ytimg.com/vi/" + videoID + "/hqdefault.jpg";
}

/// Google signs a stream URL with an `expire` epoch; the engine re-runs this
/// plugin once it passes rather than downloading a refusal.
function expirySeconds(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const value = integer(parsed.searchParams.get("expire"));
    return (value === null || value <= 0) ? null : value;
}

/// The best progressive MP4 that carries audio, or null.
///
/// `formats` holds the progressive streams; a format qualifies when it is
/// `video/mp4` and either states an audio quality or names two codecs.
function assetFrom(response, videoID, timeRange) {
    const streaming = response.streamingData || {};
    const formats = Array.isArray(streaming.formats) ? streaming.formats : [];
    if (formats.length === 0) { return null; }
    const duration = integer((response.videoDetails || {}).lengthSeconds);
    const thumbnail = bestThumbnail(response, videoID);

    let best = null;
    formats.forEach(function (format) {
        const mime = String(format.mimeType || "");
        if (mime.toLowerCase().indexOf("video/mp4") < 0) { return; }
        if (format.audioQuality === undefined && mime.indexOf(",") < 0) { return; }
        if (typeof format.url !== "string" || format.url.length === 0) { return; }
        const height = integer(format.height) || 0;
        const bitrate = integer(format.bitrate) || 0;
        if (best && !(height > best.height || (height === best.height && bitrate > best.bitrate))) {
            return;
        }
        let bytes = integer(format.contentLength);
        if (bytes === null && duration && duration > 0 && bitrate > 0) {
            bytes = Math.floor((bitrate / 8) * duration);
        }
        best = { format: format, height: height, bitrate: bitrate, bytes: bytes };
    });
    if (!best) { return null; }

    const asset = { url: best.format.url, type: "video", thumbnailURL: thumbnail,
        headers: { Referer: "https://www.youtube.com/" } };
    if (best.bytes !== null) { asset.estimatedBytes = best.bytes; }
    if (best.height > 0) { asset.quality = best.height + "p"; }
    if (timeRange) { asset.timeRange = timeRange; }
    return asset;
}

// MARK: - The player requests

function androidVRRequest(videoID, visitorData, timestamp) {
    return {
        url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
        method: "POST",
        timeout: 30,
        headers: {
            "User-Agent": ANDROID_VR_USER_AGENT,
            "X-YouTube-Client-Name": "28",
            "X-YouTube-Client-Version": ANDROID_VR_CLIENT_VERSION,
            "X-Goog-Visitor-Id": visitorData,
            Origin: "https://www.youtube.com",
        },
        body: {
            json: {
                context: {
                    client: {
                        clientName: "ANDROID_VR",
                        clientVersion: ANDROID_VR_CLIENT_VERSION,
                        deviceMake: "Oculus",
                        deviceModel: "Quest 3",
                        androidSdkVersion: 32,
                        userAgent: ANDROID_VR_USER_AGENT,
                        osName: "Android",
                        osVersion: "12L",
                        hl: "en",
                        timeZone: "UTC",
                        utcOffsetMinutes: 0,
                    },
                },
                videoId: videoID,
                playbackContext: {
                    contentPlaybackContext: {
                        html5Preference: "HTML5_PREF_WANTS",
                        signatureTimestamp: timestamp,
                    },
                },
                contentCheckOk: true,
                racyCheckOk: true,
            },
        },
    };
}

/// The public Innertube configuration the watch page exposes, with the embedded
/// player client. A response holding only ciphered or PO-token formats stays
/// unsupported and fails clearly.
function embeddedPlayerRequest(watchHTML, videoID) {
    const apiKey = firstGroup(watchHTML, /"INNERTUBE_API_KEY"\s*:\s*"([^"]+)"/);
    const version = firstGroup(watchHTML, /"INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)"/);
    if (!apiKey || !version) { return null; }
    return {
        url: "https://www.youtube.com/youtubei/v1/player?key=" + encodeURIComponent(apiKey),
        method: "POST",
        timeout: 30,
        headers: { "User-Agent": WEB_SAFARI_USER_AGENT },
        body: {
            json: {
                videoId: videoID,
                contentCheckOk: true,
                racyCheckOk: true,
                context: {
                    client: {
                        clientName: "WEB_EMBEDDED_PLAYER",
                        clientVersion: version,
                        hl: "en",
                        gl: "US",
                    },
                },
            },
        },
    };
}

function model(asset, videoID) {
    const result = {
        kind: "media", platform: "youtube", itemId: videoID, assets: [asset],
    };
    if (asset.thumbnailURL) { result.thumbnailURL = asset.thumbnailURL; }
    const expiry = expirySeconds(asset.url);
    if (expiry) { result.expiresAt = expiry; }
    return result;
}

function watchURL(videoID) {
    return "https://www.youtube.com/watch?v=" + videoID
        + "&bpctr=9999999999&has_verified=1";
}

luna.register({
    classify({ url, intent }) {
        // A transcribe intent belongs to the transcript plugin, which sits
        // below this one in the walk.
        if (intent === "transcribe") { return false; }
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const videoID = videoIDOf(parsed);
        if (videoID) { return { kind: "media", itemId: videoID }; }
        // A clip URL holds neither its video id nor its range; its own page
        // reveals both.
        return isClip(parsed) ? { kind: "media" } : false;
    },

    async ingest({ url }) {
        const parsed = luna.parseURL(url);
        if (!parsed) { return null; }
        let videoID = videoIDOf(parsed);
        let range = timeRangeOf(parsed);

        if (isClip(parsed)) {
            const clipHTML = await getText(htmlRequest(url));
            const clip = clipHTML ? clipDescriptor(clipHTML) : null;
            if (!clip) { return null; }
            videoID = clip.videoID;
            range = clip.timeRange;
        }
        if (!videoID) { return null; }

        const watchHTML = await getText(htmlRequest(watchURL(videoID)));

        // The live path: a guest session from the watch page, the active
        // player's signature timestamp, then the no-token ANDROID_VR client.
        if (watchHTML) {
            const session = bootstrap(watchHTML);
            if (session) {
                const playerJS = await getText({
                    url: session.playerJavaScriptURL,
                    timeout: 30,
                    headers: {
                        "User-Agent": WEB_SAFARI_USER_AGENT,
                        Accept: "*/*",
                        Referer: "https://www.youtube.com/",
                    },
                });
                const timestamp = playerJS ? signatureTimestamp(playerJS) : null;
                if (timestamp !== null) {
                    const playerText = await getText(androidVRRequest(
                        videoID, session.visitorData, timestamp));
                    const response = playerText ? playerResponse(playerText) : null;
                    const asset = response ? assetFrom(response, videoID, range) : null;
                    if (asset) { return model(asset, videoID); }
                }
            }

            // The watch page's own player response. Real MWEB stream URLs
            // increasingly answer 403, so this is reached only after the
            // handshake above has been tried.
            const inline = playerResponse(watchHTML);
            const inlineAsset = inline ? assetFrom(inline, videoID, range) : null;
            if (inlineAsset) { return model(inlineAsset, videoID); }
        }

        const embedHTML = await getText(htmlRequest(
            "https://www.youtube.com/embed/" + videoID + "?html5=1"));
        if (embedHTML) {
            const embed = playerResponse(embedHTML);
            const embedAsset = embed ? assetFrom(embed, videoID, range) : null;
            if (embedAsset) { return model(embedAsset, videoID); }
        }

        if (!watchHTML) { return null; }
        const request = embeddedPlayerRequest(watchHTML, videoID);
        if (!request) { return null; }
        const embeddedText = await getText(request);
        const embedded = embeddedText ? playerResponse(embeddedText) : null;
        const asset = embedded ? assetFrom(embedded, videoID, range) : null;
        return asset ? model(asset, videoID) : null;
    },
});
