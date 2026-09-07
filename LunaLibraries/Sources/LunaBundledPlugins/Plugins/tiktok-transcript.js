/* luna-plugin
{
  "id": "app.luna.tiktok.transcript",
  "name": "TikTok transcript",
  "version": "1.0.0",
  "api": 1,
  "description": "Reads a TikTok video as an article: its captions when it has them, else a transcript of its audio.",
  "produces": ["article"],
  "match": { "hosts": ["tiktok.com", "*.tiktok.com"] },
  "priority": 90,
  "capabilities": ["fetch", "html"]
}
*/

// The transcript twin of `tiktok.js`. The watch page's item carries
// `video.subtitleInfos`, TikTok's own captions as WebVTT files; when one is
// there the text is read straight from it and no media is fetched. Otherwise
// the video file the media plugin would download is the transcription source.
// TikTok publishes no audio-only file. `tiktok.js` outranks this plugin and
// declines a transcribe intent.

const REHYDRATION_SCRIPT_ID = "__UNIVERSAL_DATA_FOR_REHYDRATION__";
const REHYDRATION_KEYS = ["webapp.video-detail", "webapp.reflow.video.detail"];

const SAFARI_USER_AGENT =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15";

/// The headers Luna's own download engine sends the TikTok CDN, which refuses
/// a request without its Referer.
const CDN_HEADERS = {
    "User-Agent": SAFARI_USER_AGENT,
    Referer: "https://www.tiktok.com/",
};

/// TikTok names caption languages as ISO 639-2 plus a region (`eng-US`).
/// The article's `language` is BCP-47, so the common codes are mapped and an
/// unknown one is left out rather than guessed.
const LANGUAGE_CODES = {
    eng: "en", spa: "es", fra: "fr", deu: "de", por: "pt", ita: "it", jpn: "ja",
    kor: "ko", zho: "zh", cmn: "zh", rus: "ru", ara: "ar", hin: "hi", ind: "id",
    vie: "vi", tur: "tr", nld: "nl", pol: "pl", tha: "th", swe: "sv", dan: "da",
    nor: "no", fin: "fi", ell: "el", heb: "he", ukr: "uk", ces: "cs", hun: "hu",
    ron: "ro", msa: "ms", fil: "fil", tgl: "tl",
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

function getHTML(url) {
    return getText({
        url: url,
        userAgent: "safari",
        headers: { Accept: "text/html,application/xhtml+xml" },
    });
}

function scriptJSON(document, id) {
    const scripts = document.querySelectorAll("script");
    for (let i = 0; i < scripts.length; i++) {
        if (scripts[i].getAttribute("id") !== id) { continue; }
        try {
            return JSON.parse(scripts[i].innerHTML);
        } catch (error) {
            return null;
        }
    }
    return null;
}

function itemStruct(document) {
    const rehydration = scriptJSON(document, REHYDRATION_SCRIPT_ID);
    const scope = rehydration && rehydration.__DEFAULT_SCOPE__;
    if (scope) {
        for (let i = 0; i < REHYDRATION_KEYS.length; i++) {
            const detail = scope[REHYDRATION_KEYS[i]];
            const item = detail && detail.itemInfo && detail.itemInfo.itemStruct;
            if (item) { return item; }
        }
    }
    const apiData = scriptJSON(document, "api-data");
    const videoDetail = apiData && apiData.videoDetail;
    const item = videoDetail && videoDetail.itemInfo && videoDetail.itemInfo.itemStruct;
    return item || null;
}

/// TikTok signs a play address with an expiry, in epoch seconds.
function expirySeconds(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const value = parseInt(parsed.searchParams.get("expire") || "", 10);
    return isNaN(value) || value <= 0 ? null : value;
}

/// The watermark-free `playAddr`, else the watermarked `downloadAddr`.
function videoAddress(item) {
    const video = item.video;
    if (!video) { return null; }
    const address = (typeof video.playAddr === "string" && video.playAddr.length > 0)
        ? video.playAddr
        : video.downloadAddr;
    return (typeof address === "string" && address.length > 0) ? address : null;
}

// MARK: - Captions

/// The caption to read: TikTok's own speech recognition first, a machine
/// translation only when nothing else is offered.
function captionInfo(item) {
    const video = item.video || {};
    const infos = Array.isArray(video.subtitleInfos) ? video.subtitleInfos : [];
    const usable = infos.filter(function (info) {
        return info && typeof info.Url === "string" && info.Url.length > 0
            && String(info.Format || "webvtt").toLowerCase() === "webvtt";
    });
    if (usable.length === 0) { return null; }
    const recognised = usable.filter(function (info) {
        return String(info.Source || "").toUpperCase() === "ASR";
    });
    return recognised[0] || usable[0];
}

function languageTag(info) {
    const raw = String((info && info.LanguageCodeName) || "");
    const parts = raw.split("-");
    if (parts.length === 0 || parts[0].length === 0) { return null; }
    const primary = parts[0].toLowerCase();
    let tag = null;
    if (primary.length === 2) {
        tag = primary;
    } else if (LANGUAGE_CODES[primary]) {
        tag = LANGUAGE_CODES[primary];
    }
    if (!tag) { return null; }
    return parts.length > 1 && /^[A-Za-z]{2}$/.test(parts[1]) ? tag + "-" + parts[1].toUpperCase() : tag;
}

/// `hh:mm:ss.mmm` or `mm:ss.mmm` as seconds, or null.
function vttSeconds(stamp) {
    const match = /^(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})$/.exec(String(stamp).trim());
    if (!match) { return null; }
    const hours = match[1] === undefined ? 0 : Number(match[1]);
    return hours * 3600 + Number(match[2]) * 60 + Number(match[3])
        + Number(match[4].padEnd(3, "0")) / 1000;
}

/// WebVTT cues as `{ start, end, text }`. Header, `NOTE`, `STYLE` and `REGION`
/// blocks are skipped; a cue may open with an identifier line.
function vttCues(text) {
    const blocks = String(text).replace(/\r\n?/g, "\n").split(/\n\s*\n/);
    const cues = [];
    blocks.forEach(function (block) {
        const lines = block.split("\n").filter(function (line) { return line.trim().length > 0; });
        if (lines.length === 0) { return; }
        const first = lines[0].trim();
        if (/^WEBVTT/.test(first) || /^(NOTE|STYLE|REGION)\b/.test(first)) { return; }
        let timingIndex = lines.findIndex(function (line) { return line.indexOf("-->") >= 0; });
        if (timingIndex < 0) { return; }
        const timing = lines[timingIndex].split("-->");
        const start = vttSeconds(timing[0]);
        const end = vttSeconds(String(timing[1] || "").trim().split(/\s+/)[0]);
        if (start === null || end === null) { return; }
        const body = lines.slice(timingIndex + 1).join(" ");
        cues.push({ start: start, end: end, text: body });
    });
    return cues;
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

/// Free text (the item's description) as escaped paragraphs.
function textHTML(text) {
    const blocks = String(text || "").split(/\r?\n\s*\r?\n/);
    const paragraphs = [];
    blocks.forEach(function (block) {
        const flat = block.replace(/\s+/g, " ").trim();
        if (flat.length > 0) { paragraphs.push(flat); }
    });
    return paragraphsHTML(paragraphs);
}

// MARK: - The Model

/// `fallbackID` is the id the URL named, for an item struct that omits its own.
function baseModel(item, html, fallbackID) {
    const id = (typeof item.id === "string" && item.id.length > 0) ? item.id : (fallbackID || "video");
    const description = typeof item.desc === "string" ? item.desc.replace(/\s+/g, " ").trim() : "";
    const model = {
        kind: "article",
        title: description.length > 0 ? description.slice(0, 300) : "TikTok " + id,
    };
    if (html.length > 0) { model.html = html; }
    const author = item.author || {};
    if (typeof author.nickname === "string" && author.nickname.length > 0) {
        model.author = author.nickname.slice(0, 300);
    } else if (typeof author.uniqueId === "string" && author.uniqueId.length > 0) {
        model.author = "@" + author.uniqueId;
    }
    return model;
}

luna.register({
    classify({ url }) {
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const parts = String(parsed.pathname || "").split("/").filter(function (part) {
            return part.length > 0;
        });
        for (let i = 0; i < parts.length; i++) {
            if (parts[i] === "video" && /^[0-9]+$/.test(parts[i + 1] || "")) {
                return { kind: "article", itemId: parts[i + 1] };
            }
        }
        // A short `vm.`/`vt.`/`/t/` link carries no id; the page it lands on
        // holds the item.
        return { kind: "article" };
    },

    async ingest({ url, claim, page }) {
        const claimedID = claim && claim.itemId;
        let item = null;
        if (page && typeof page.html === "string") {
            item = itemStruct(luna.html.parse(page.html, url));
        }
        if (!item) {
            const html = await getHTML(url);
            if (!html) { return null; }
            item = itemStruct(luna.html.parse(html, url));
        }
        if (!item) { return null; }
        if (item.imagePost && Array.isArray(item.imagePost.images)
            && item.imagePost.images.length > 0) {
            // A photo carousel has no speech.
            return null;
        }

        const caption = captionInfo(item);
        if (caption) {
            const vtt = await getText({
                url: caption.Url,
                userAgent: "safari",
                headers: { Accept: "text/vtt,*/*", Referer: "https://www.tiktok.com/" },
            });
            const paragraphs = vtt ? paragraphsFromCues(vttCues(vtt)) : [];
            if (paragraphs.length > 0) {
                const model = baseModel(item, paragraphsHTML(paragraphs), claimedID);
                const language = languageTag(caption);
                if (language) { model.language = language; }
                return model;
            }
        }

        const address = videoAddress(item);
        if (!address) { return null; }
        const model = baseModel(item, textHTML(item.desc), claimedID);
        model.transcription = { url: address, type: "video", headers: CDN_HEADERS };
        const expiry = expirySeconds(address);
        if (expiry) { model.transcription.expiresAt = expiry; }
        return model;
    },
});
