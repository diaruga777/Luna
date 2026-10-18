/* luna-plugin
{
  "id": "app.luna.youtube.transcript",
  "name": "YouTube transcript",
  "version": "1.0.0",
  "api": 1,
  "description": "Reads a YouTube video as an article: its captions when it has them, else a transcript of its audio.",
  "produces": ["article"],
  "match": {
    "hosts": [
      "youtube.com", "*.youtube.com", "youtu.be",
      "youtube-nocookie.com", "*.youtube-nocookie.com"
    ]
  },
  "priority": 90,
  "capabilities": ["fetch"]
}
*/

// The transcript twin of `youtube.js`. It runs the same guest-session ladder
// to the same player response, then reads that response for the cheapest
// source of the spoken words, in this order:
//
//   1. a caption track — the text is already there, no file is fetched;
//   2. an audio-only adaptive stream — a few megabytes per hour of speech;
//   3. the progressive MP4 with sound — the file `youtube.js` would download.
//
// Sources 2 and 3 return an `article` Model with a `transcription` spec that
// Luna downloads, transcribes on device and deletes. `youtube.js` outranks
// this plugin (priority 100) and declines a transcribe intent, so a plain
// save still downloads the video and a transcribe request reaches this file.
// Clips are declined: a clip names a range, and a transcript covers the video.

const ANDROID_VR_CLIENT_VERSION = "1.65.10";
const ANDROID_VR_USER_AGENT =
    "com.google.android.apps.youtube.vr.oculus/1.65.10 "
    + "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
const WEB_SAFARI_USER_AGENT =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)";
const CONSENT_COOKIE = "PREF=hl=en&tz=UTC; SOCS=CAI";

const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;
const ID_PATH_KINDS = ["shorts", "live", "embed", "v"];

/// The headers Luna's own download engine sends the video CDN.
const CDN_HEADERS = {
    "User-Agent": WEB_SAFARI_USER_AGENT,
    Referer: "https://www.youtube.com/",
};

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

/// Google signs a stream URL with an `expire` epoch, in seconds.
function expirySeconds(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const value = integer(parsed.searchParams.get("expire"));
    return (value === null || value <= 0) ? null : value;
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

function watchURL(videoID) {
    return "https://www.youtube.com/watch?v=" + videoID
        + "&bpctr=9999999999&has_verified=1";
}

/// The same ladder `youtube.js` climbs, stopping at the first player response
/// rather than the first asset: captions and adaptive streams live on the
/// response itself.
async function playerResponseFor(videoID) {
    const watchHTML = await getText(htmlRequest(watchURL(videoID)));
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
                if (response) { return response; }
            }
        }
        const inline = playerResponse(watchHTML);
        if (inline) { return inline; }
    }

    const embedHTML = await getText(htmlRequest(
        "https://www.youtube.com/embed/" + videoID + "?html5=1"));
    if (embedHTML) {
        const embed = playerResponse(embedHTML);
        if (embed) { return embed; }
    }

    if (!watchHTML) { return null; }
    const request = embeddedPlayerRequest(watchHTML, videoID);
    if (!request) { return null; }
    const embeddedText = await getText(request);
    return embeddedText ? playerResponse(embeddedText) : null;
}

// MARK: - Transcript text

const PARAGRAPH_GAP_SECONDS = 2;
const PARAGRAPH_WORD_LIMIT = 90;

function escapeHTML(text) {
    return String(text)
        .split("&").join("&amp;")
        .split("<").join("&lt;")
        .split(">").join("&gt;")
        .split("\"").join("&quot;");
}

function decodeEntities(text) {
    return String(text)
        .replace(/&#(\d+);/g, function (whole, code) { return String.fromCharCode(Number(code)); })
        .replace(/&#x([0-9a-fA-F]+);/g, function (whole, code) {
            return String.fromCharCode(parseInt(code, 16));
        })
        .split("&nbsp;").join(" ")
        .split("&quot;").join("\"")
        .split("&#39;").join("'")
        .split("&apos;").join("'")
        .split("&lt;").join("<")
        .split("&gt;").join(">")
        .split("&amp;").join("&");
}

/// Caption text with markup and entities removed and whitespace collapsed.
function cleanCueText(raw) {
    return decodeEntities(String(raw || "").replace(/<[^>]*>/g, " "))
        .replace(/\s+/g, " ").trim();
}

function wordCount(text) {
    return text.split(/\s+/).filter(function (word) { return word.length > 0; }).length;
}

function endsSentence(text) {
    return /[.!?]["')\]]?$/.test(text);
}

/// Cues `{ start, end, text }` (seconds) as paragraphs, by the rule the Swift
/// transcript builder applies: a new paragraph at a silence of
/// PARAGRAPH_GAP_SECONDS or more, or past PARAGRAPH_WORD_LIMIT words once a cue
/// ends a sentence. A cue repeating the previous cue's text (rolling captions)
/// is dropped.
function paragraphsFromCues(cues) {
    const paragraphs = [];
    let current = [];
    let currentWords = 0;
    let previous = null;
    function flush() {
        if (current.length > 0) { paragraphs.push(current.join(" ")); }
        current = [];
        currentWords = 0;
    }
    cues.forEach(function (cue) {
        const text = cleanCueText(cue.text);
        if (text.length === 0) { return; }
        if (previous && text === previous.text) { return; }
        if (previous && current.length > 0
            && cue.start - previous.end >= PARAGRAPH_GAP_SECONDS) {
            flush();
        }
        current.push(text);
        currentWords += wordCount(text);
        previous = { text: text, end: cue.end };
        if (currentWords > PARAGRAPH_WORD_LIMIT && endsSentence(text)) { flush(); }
    });
    flush();
    return paragraphs;
}

function paragraphsHTML(paragraphs) {
    return paragraphs.map(function (paragraph) {
        return "<p>" + escapeHTML(paragraph) + "</p>";
    }).join("\n");
}

/// Free text (a description) as escaped paragraphs, split at blank lines.
function textHTML(text) {
    const blocks = String(text || "").split(/\r?\n\s*\r?\n/);
    const paragraphs = [];
    blocks.forEach(function (block) {
        const flat = block.replace(/\s+/g, " ").trim();
        if (flat.length > 0) { paragraphs.push(flat); }
    });
    return paragraphsHTML(paragraphs);
}

// MARK: - Captions

/// The caption track to read, or null. Manual captions in the video's default
/// audio language first, then any manual track, then an automatic one.
function captionTrack(response) {
    const renderer = response.captions && response.captions.playerCaptionsTracklistRenderer;
    if (!renderer) { return null; }
    const all = Array.isArray(renderer.captionTracks) ? renderer.captionTracks : [];
    const tracks = all.filter(function (track) {
        return track && typeof track.baseUrl === "string" && track.baseUrl.length > 0;
    });
    if (tracks.length === 0) { return null; }

    let preferred = (response.videoDetails || {}).defaultAudioLanguage || null;
    const audioTracks = Array.isArray(renderer.audioTracks) ? renderer.audioTracks : [];
    for (let i = 0; i < audioTracks.length; i++) {
        const index = audioTracks[i] && audioTracks[i].defaultCaptionTrackIndex;
        if (typeof index === "number" && all[index] && typeof all[index].languageCode === "string") {
            preferred = all[index].languageCode;
            break;
        }
    }
    function sameLanguage(track) {
        if (!preferred || typeof track.languageCode !== "string") { return false; }
        return track.languageCode.split("-")[0].toLowerCase()
            === String(preferred).split("-")[0].toLowerCase();
    }
    const manual = tracks.filter(function (track) { return track.kind !== "asr"; });
    const automatic = tracks.filter(function (track) { return track.kind === "asr"; });
    return manual.find(sameLanguage) || manual[0]
        || automatic.find(sameLanguage) || automatic[0] || null;
}

/// The track's cues from the `json3` timed-text format: one event per line,
/// its text split into `segs`. An `aAppend` event continues the previous line.
async function captionCues(track) {
    const separator = track.baseUrl.indexOf("?") >= 0 ? "&" : "?";
    const text = await getText({
        url: track.baseUrl + separator + "fmt=json3",
        timeout: 30,
        headers: { "User-Agent": WEB_SAFARI_USER_AGENT, Accept: "application/json" },
    });
    if (!text) { return null; }
    let payload;
    try {
        payload = JSON.parse(text);
    } catch (error) {
        return null;
    }
    const events = payload && Array.isArray(payload.events) ? payload.events : [];
    const cues = [];
    events.forEach(function (event) {
        if (!event || !Array.isArray(event.segs)) { return; }
        const words = event.segs.map(function (segment) {
            return segment && typeof segment.utf8 === "string" ? segment.utf8 : "";
        }).join("").replace(/\n/g, " ").trim();
        if (words.length === 0) { return; }
        const start = (integer(event.tStartMs) || 0) / 1000;
        const duration = (integer(event.dDurationMs) || 0) / 1000;
        if (event.aAppend === 1 && cues.length > 0) {
            const last = cues[cues.length - 1];
            last.text += " " + words;
            last.end = Math.max(last.end, start + duration);
            return;
        }
        cues.push({ start: start, end: start + duration, text: words });
    });
    return cues;
}

// MARK: - The files

/// The audio-only adaptive stream with the highest bitrate that has a plain
/// URL. A ciphered entry needs a signature this plugin cannot compute.
function audioFormat(response) {
    const streaming = response.streamingData || {};
    const formats = Array.isArray(streaming.adaptiveFormats) ? streaming.adaptiveFormats : [];
    let best = null;
    formats.forEach(function (format) {
        if (!format || !/^audio\/mp4/i.test(String(format.mimeType || ""))) { return; }
        if (typeof format.url !== "string" || format.url.length === 0) { return; }
        if (format.signatureCipher !== undefined || format.cipher !== undefined) { return; }
        const bitrate = integer(format.bitrate) || 0;
        if (!best || bitrate > best.bitrate) { best = { url: format.url, bitrate: bitrate }; }
    });
    return best;
}

/// The best progressive MP4 that carries audio, the pick `youtube.js` makes.
function progressiveVideo(response) {
    const streaming = response.streamingData || {};
    const formats = Array.isArray(streaming.formats) ? streaming.formats : [];
    let best = null;
    formats.forEach(function (format) {
        if (!format) { return; }
        const mime = String(format.mimeType || "");
        if (mime.toLowerCase().indexOf("video/mp4") < 0) { return; }
        if (format.audioQuality === undefined && mime.indexOf(",") < 0) { return; }
        if (typeof format.url !== "string" || format.url.length === 0) { return; }
        const height = integer(format.height) || 0;
        const bitrate = integer(format.bitrate) || 0;
        if (best && !(height > best.height || (height === best.height && bitrate > best.bitrate))) {
            return;
        }
        best = { url: format.url, height: height, bitrate: bitrate };
    });
    return best;
}

function transcriptionSpec(url, type) {
    const spec = { url: url, type: type, headers: CDN_HEADERS };
    const expiry = expirySeconds(url);
    if (expiry) { spec.expiresAt = expiry; }
    return spec;
}

function articleModel(details, videoID, html, transcription, language) {
    const title = (typeof details.title === "string" && details.title.trim().length > 0)
        ? details.title.trim().slice(0, 300)
        : "YouTube " + videoID;
    const model = { kind: "article", title: title };
    if (typeof html === "string" && html.length > 0) { model.html = html; }
    if (typeof details.author === "string" && details.author.length > 0) {
        model.author = details.author.slice(0, 300);
    }
    if (typeof language === "string" && language.length > 0) { model.language = language; }
    if (transcription) { model.transcription = transcription; }
    return model;
}

luna.register({
    classify({ url }) {
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const videoID = videoIDOf(parsed);
        return videoID ? { kind: "article", itemId: videoID } : false;
    },

    async ingest({ url, claim }) {
        const parsed = luna.parseURL(url);
        if (!parsed) { return null; }
        const videoID = (claim && claim.itemId) || videoIDOf(parsed);
        if (!videoID) { return null; }

        const response = await playerResponseFor(videoID);
        if (!response) { return null; }
        const details = response.videoDetails || {};
        const spokenLanguage = typeof details.defaultAudioLanguage === "string"
            ? details.defaultAudioLanguage : null;

        const track = captionTrack(response);
        if (track) {
            const cues = await captionCues(track);
            const paragraphs = cues ? paragraphsFromCues(cues) : [];
            if (paragraphs.length > 0) {
                return articleModel(
                    details, videoID, paragraphsHTML(paragraphs), null,
                    typeof track.languageCode === "string" ? track.languageCode : spokenLanguage);
            }
        }

        const description = textHTML(details.shortDescription);
        const audio = audioFormat(response);
        if (audio) {
            return articleModel(
                details, videoID, description, transcriptionSpec(audio.url, "audio"),
                spokenLanguage);
        }
        const video = progressiveVideo(response);
        if (video) {
            return articleModel(
                details, videoID, description, transcriptionSpec(video.url, "video"),
                spokenLanguage);
        }
        return null;
    },
});
