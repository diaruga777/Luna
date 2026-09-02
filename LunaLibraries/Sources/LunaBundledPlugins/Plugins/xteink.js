/* luna-plugin
{
  "id": "app.luna.xteink",
  "name": "Xteink",
  "version": "1.0.0",
  "api": 1,
  "description": "Delivers saved articles to an Xteink X3 pocket e-reader over the CrossPoint rendezvous.",
  "capabilities": ["bluetooth", "wifi", "fetch", "files", "crypto", "secrets", "storage", "settings", "notifications", "exports", "ui"],
  "background": true,
  "bluetooth": {
    "services": ["6F9F0A00-9B1D-4D1F-9F53-5B6B8B3D0F10"],
    "pairing": "accessorySetupKit",
    "standingConnect": true,
    "role": "central"
  },
  "settings": [
    { "key": "enabled", "type": "toggle", "label": "Send to Xteink", "default": false,
      "help": "Queued articles are delivered when the reader opens a Luna Sync window." },
    { "key": "device", "type": "pairedDevice", "label": "Reader", "required": true,
      "help": "Open File Transfer → Pair Luna on the reader, then pair here." },
    { "key": "unpair", "type": "action", "label": "Unpair" }
  ],
  "export": {
    "kinds": ["article"],
    "input": "epub",
    "inputOptions": { "epub": { "profile": "compact" } },
    "title": "Send to Xteink",
    "symbol": "books.vertical",
    "destination": true,
    "requiresSettings": ["device"]
  }
}
*/

// The reader opens the window, never the phone. A share-row send is
// enqueue-only: with no live session `export` answers `retry`, and the core
// keeps the item queued at no retry cost. Delivery happens inside
// `onBluetooth("connected")`, which awaits `luna.exports.deliverQueued()`.
//
// Wire constants are v1 and must stay stable: an installed reader has to keep
// working after Luna updates. `XteinkSyncProtocol` (LunaSend) is the Swift
// copy Luna Reader still runs, and `XteinkPluginParityTests` pins the hello
// HMAC against it.

const SERVICE = "6F9F0A00-9B1D-4D1F-9F53-5B6B8B3D0F10";
const CONTROL = "6F9F0A01-9B1D-4D1F-9F53-5B6B8B3D0F10";
const DATA_IN = "6F9F0A02-9B1D-4D1F-9F53-5B6B8B3D0F10";
const STATUS = "6F9F0A03-9B1D-4D1F-9F53-5B6B8B3D0F10";

const VERSION = 1;
/// The host id the reader stores and the hello signs over. The migrated
/// Keychain secret is keyed by it, so changing it un-pairs every reader.
const HOST_ID = "luna-ios";

/// The inclusive BLE ceiling. A larger book asks the reader for Wi-Fi.
const BLE_MAX_BYTES = 200 * 1024;
/// The reader declares its durable-receipt stride as "ckpt" in every transfer
/// status. This is the one firmware build that predates the field.
const DEFAULT_CKPT_BYTES = 8192;
/// Keeps the stream moving while a confirmation is in flight.
const IN_FLIGHT_MARGIN_BYTES = 1024;

const CONTROL_ACK_TIMEOUT = 15;
const CHECKPOINT_TIMEOUT = 10;
const UPLOAD_PATH = "/upload?path=/Books";
/// The reader's own pending remote deletes, filled on delivery and drained in
/// the next normal window.
const PENDING_DELETES = "pendingDeletes";

/// The window's authenticated link, while one is open.
///
/// `export` runs INSIDE `onBluetooth` — the core invokes it from the
/// `luna.exports.deliverQueued()` the rendezvous awaits — so it inherits that
/// window's hello and the reader's declared checkpoint stride instead of
/// authenticating a second time.
let activeLink = null;

// MARK: - Bytes

const HEX = "0123456789abcdef";

function hex(bytes) {
    const parts = [];
    for (let i = 0; i < bytes.length; i += 1) {
        parts.push(HEX[(bytes[i] >> 4) & 0xf] + HEX[bytes[i] & 0xf]);
    }
    return parts.join("");
}

/// `luna.crypto` answers base64; the reader's protocol is lower-case hex.
function hexOfBase64(base64) {
    return hex(luna.bytes.fromBase64(base64));
}

function utf8Base64(text) {
    return luna.bytes.toBase64(luna.bytes.utf8Encode(text));
}

function textOfBase64(base64) {
    return luna.bytes.utf8Decode(luna.bytes.fromBase64(base64));
}

/// A data frame: a 4-byte little-endian sequence header, then the payload.
function frame(sequence, payload) {
    const out = new Uint8Array(payload.length + 4);
    out[0] = sequence & 0xff;
    out[1] = (sequence >>> 8) & 0xff;
    out[2] = (sequence >>> 16) & 0xff;
    out[3] = (sequence >>> 24) & 0xff;
    out.set(payload, 4);
    return luna.bytes.toBase64(out);
}

/// CrossPoint's X3-side filename validator permits only this ASCII set. The
/// display title is untouched; only the transport name is normalized, and
/// deterministically, so a resume targets the same remote file.
function x3FileName(name) {
    const normalized = String(name || "").replace(/[^A-Za-z0-9._-]/g, "-");
    return normalized.length > 0 ? normalized : "Luna.epub";
}

// MARK: - Status

/// One status notification. A status is size-capped by BLE (MTU-3 bytes) and
/// the reader truncates the rest on air, so no message carries every field and
/// a parser must tolerate any subset being absent.
function parseStatus(base64) {
    try {
        return JSON.parse(textOfBase64(base64));
    } catch (error) {
        return null;
    }
}

function isFailure(status) {
    return status.ok === false || (typeof status.error === "string" && status.error.length > 0);
}

/// The link's live bookkeeping: the confirmed offset, the reader's stride, and
/// the read ids it hands back.
function newLink() {
    return { confirmed: 0, sequence: 0, ckpt: DEFAULT_CKPT_BYTES, readIDs: [], wifi: null, readReport: false };
}

function applyStatus(link, status) {
    if (status.win === "rr") { link.readReport = true; }
    if (typeof status.received === "number") { link.confirmed = status.received; }
    if (typeof status.resume_offset === "number") { link.confirmed = status.resume_offset; }
    if (typeof status.next_sequence === "number") { link.sequence = status.next_sequence; }
    if (typeof status.ckpt === "number" && status.ckpt > 0) { link.ckpt = status.ckpt; }
    if (status.wifi && typeof status.wifi.mode === "string") { link.wifi = status.wifi; }
    if (Array.isArray(status.read_ids)) {
        for (const id of status.read_ids) {
            if (typeof id === "string" && link.readIDs.indexOf(id) < 0) { link.readIDs.push(id); }
        }
    }
}

// MARK: - Control

async function writeControl(session, op, values) {
    const payload = Object.assign({}, values || {});
    payload.op = op;
    payload.version = VERSION;
    await session.write(CONTROL, utf8Base64(JSON.stringify(payload)), { response: true });
}

/// Sends a control operation and waits for its `op_ack`.
///
/// A successful GATT write only says the reader accepted bytes. The reader may
/// publish other statuses first — a checkpoint, a read-id handback — so every
/// status is applied to the link and only the matching ack finishes the call.
async function control(session, link, op, values) {
    await writeControl(session, op, values);
    const deadline = Date.now() + CONTROL_ACK_TIMEOUT * 1000;
    while (Date.now() < deadline) {
        const status = parseStatus(await session.next(STATUS, { timeout: CONTROL_ACK_TIMEOUT }));
        if (!status) { continue; }
        applyStatus(link, status);
        if (isFailure(status)) {
            throw new luna.LunaError("reader-rejected", status.error || "the reader rejected " + op);
        }
        if (status.op_ack === op) { return status; }
    }
    throw new luna.LunaError("timed-out", "no " + op + " ack arrived");
}

/// The authenticated hello. HMAC-SHA256 over `nonce|host_id|1`, keyed by the
/// pairing secret's own bytes.
async function authenticate(session, link, nonce) {
    const secret = await luna.secrets.get("pairingSecret");
    if (!secret) {
        throw new luna.LunaError("pairing-required", "no pairing secret on this device");
    }
    const message = nonce + "|" + HOST_ID + "|" + VERSION;
    const response = hexOfBase64(await luna.crypto.hmacSHA256(secret, message));
    await control(session, link, "hello", { host_id: HOST_ID, response: response });
}

/// The nonce the reader publishes for this connection.
///
/// The reader may have emitted it before iOS subscribed, so an explicit read
/// follows the subscribe rather than waiting for a notification that already
/// happened.
async function openLink(session) {
    const link = newLink();
    await session.discover(SERVICE);
    await session.subscribe(STATUS);
    const first = parseStatus(await session.read(STATUS));
    if (!first || typeof first.nonce !== "string") {
        throw new luna.LunaError("no-nonce", "the reader published no nonce");
    }
    applyStatus(link, first);
    return { link: link, nonce: first.nonce };
}

// MARK: - The BLE transfer

/// Whether the sender must wait for the reader's next confirmation.
///
/// `canSendWriteWithoutResponse` is local backpressure only: it says the
/// phone's controller can queue another packet, not that the reader has
/// durably written the earlier ones. An unpaced stream outruns the X3's SD
/// writes, overflows its frame pool and starves its allocator.
function shouldPause(sent, link, total) {
    if (sent >= total) { return false; }
    return sent - link.confirmed >= link.ckpt + IN_FLIGHT_MARGIN_BYTES;
}

/// Waits for any status carrying the reader's offset.
async function awaitCheckpoint(session, link) {
    const deadline = Date.now() + CHECKPOINT_TIMEOUT * 1000;
    while (Date.now() < deadline) {
        const status = parseStatus(await session.next(STATUS, { timeout: CHECKPOINT_TIMEOUT }));
        if (!status) { continue; }
        applyStatus(link, status);
        if (isFailure(status)) {
            throw new luna.LunaError("reader-rejected", status.error || "the transfer failed");
        }
        if (typeof status.received === "number" || typeof status.resume_offset === "number") {
            return;
        }
    }
    throw new luna.LunaError("timed-out", "no reader checkpoint arrived");
}

async function sendOverBLE(session, link, bytes, fileName, articleID, queuedRemaining) {
    const digest = hexOfBase64(await luna.crypto.sha256({ base64: luna.bytes.toBase64(bytes) }));
    const chunk = Math.max(1, session.mtu - 4);
    const start = { kind: "book", name: fileName, size: bytes.length, sha256: digest,
                    resume: true, chunk_size: chunk };
    if (articleID) { start.article_id = String(articleID).toLowerCase(); }
    if (typeof queuedRemaining === "number") { start.queue_remaining = queuedRemaining; }
    await control(session, link, "start_put", start);

    let offset = Math.min(link.confirmed, bytes.length);
    let sequence = link.sequence;
    while (offset < bytes.length) {
        while (shouldPause(offset, link, bytes.length)) {
            await awaitCheckpoint(session, link);
        }
        const end = Math.min(offset + chunk, bytes.length);
        await session.write(DATA_IN, frame(sequence, bytes.subarray(offset, end)), { response: false });
        offset = end;
        sequence = (sequence + 1) >>> 0;
    }
    await control(session, link, "commit", { sha256: digest, size: bytes.length });
}

// MARK: - The Wi-Fi transfer

/// Asks the reader for a network and uploads over it.
///
/// The custom X3 fork treats its own secured access point as the default, so a
/// remembered but unreachable home network cannot strand a travelling phone. A
/// station offer uploads directly; an access-point offer is joined for the
/// transfer and dropped afterwards. iOS joins a network only in the
/// foreground, which `luna.wifi.join` reports as code `background`.
async function sendOverWiFi(session, link, base64, fileName, title) {
    await control(session, link, "wifi_request", { prefer_ap: true });
    if (!link.wifi || typeof link.wifi.ip !== "string") {
        throw new luna.LunaError("no-offer", "the reader offered no network");
    }
    const offer = link.wifi;
    const joined = offer.mode === "ap";
    if (joined) {
        try {
            await luna.wifi.join({ ssid: offer.ssid, passphrase: offer.password, joinOnce: true });
        } catch (error) {
            if (error && error.code === "background") {
                await luna.notifications.post({
                    title: "Xteink is ready",
                    body: "Open Luna to send " + title + " over the reader’s Wi‑Fi.",
                    identifier: "xteink-wifi-transfer",
                });
                throw new luna.LunaError("background", "the join needs Luna in the foreground");
            }
            throw error;
        }
    }
    try {
        await upload(offer.ip, fileName, base64);
    } finally {
        if (joined) { await luna.wifi.forget(offer.ssid); }
    }
}

/// CrossPoint's own upload endpoint. Luna treats a 2xx as authoritative; the
/// firmware rejects a zero-byte file.
async function upload(host, fileName, base64) {
    const response = await luna.fetch({
        url: "http://" + host + UPLOAD_PATH,
        method: "POST",
        body: { multipart: [{ name: "file", filename: fileName,
                              mime: "application/epub+zip", base64: base64 }] },
        timeout: 120,
    });
    if (!response.ok) {
        throw new luna.LunaError("upload-rejected", "CrossPoint refused the upload");
    }
}

// MARK: - Reconciliation

/// Books the reader reports as finished.
///
/// The reader marks a Luna-synced book read when the user reaches its end and
/// re-reports any still-pending id at the start of every later window. Luna
/// clears the send so the book is never delivered twice, then acks — a plain
/// write, not a control operation, because the ack slot may be busy.
async function reconcile(session, link) {
    if (link.readIDs.length === 0) { return; }
    const ids = link.readIDs.slice();
    link.readIDs = [];
    for (const id of ids) {
        try {
            await luna.exports.markSent(id);
        } catch (error) {
            luna.log("read-state reconcile failed", { id: id });
        }
    }
    await writeControl(session, "read_ack", { ids: ids });
}

/// Removes the books whose reading finished in Luna. The reader treats a
/// missing file as its own success, so anything left pending just waits for
/// the next window.
async function drainPendingDeletes(session, link) {
    const deletes = luna.storage.collection(PENDING_DELETES);
    const rows = await deletes.find({}, { limit: 50 });
    for (const row of rows) {
        const name = (row.doc || {}).remoteName;
        if (!name) {
            await deletes.delete(row.id);
            continue;
        }
        try {
            await control(session, link, "delete", { name: name });
            await deletes.delete(row.id);
        } catch (error) {
            if (isMissingFile(error)) { await deletes.delete(row.id); }
        }
    }
}

function isMissingFile(error) {
    const message = String((error && error.message) || "").toLowerCase();
    return message.indexOf("no such file") >= 0 || message.indexOf("not found") >= 0
        || message.indexOf("enoent") >= 0;
}

// MARK: - Hooks

luna.register({
    /// Delivers one queued article.
    ///
    /// With no live session this is enqueue-only: `retry` leaves the item
    /// queued with no failure count and no backoff, and the reader's next
    /// window collects it.
    async export(input) {
        const session = luna.bluetooth.session();
        if (!session) {
            return { status: "retry", message: "Waiting for the reader" };
        }
        if (!input.file) {
            return { status: "failed", message: "no EPUB to send", hard: true };
        }
        const fileName = x3FileName(input.file.name || input.title + ".epub");
        try {
            let link = activeLink;
            if (!link) {
                const state = await openLink(session);
                await authenticate(session, state.link, state.nonce);
                link = state.link;
            }
            const base64 = await luna.files.read(input.file, "base64");
            const bytes = luna.bytes.fromBase64(base64);
            if (bytes.length <= BLE_MAX_BYTES) {
                await sendOverBLE(
                    session, link, bytes, fileName, input.saveId, input.queuedRemaining);
            } else {
                await sendOverWiFi(session, link, base64, fileName, input.title);
            }
            await recordDelivery(input.saveId, fileName);
            return { status: "sent" };
        } catch (error) {
            return exportFailure(error, fileName);
        }
    },

    /// The rendezvous. The core holds the service lock for this whole call, so
    /// only one Luna process talks to a given window.
    async onBluetooth(event) {
        if (event.type !== "connected") {
            if (event.type === "disconnected" || event.type === "unpaired") {
                await luna.settings.set("_status", "off");
            }
            return;
        }
        await luna.settings.set("_status", "live");
        const session = luna.bluetooth.session();
        if (!session) { return; }
        try {
            const state = await openLink(session);
            await authenticate(session, state.link, state.nonce);
            activeLink = state.link;
            await reconcile(session, state.link);
            // A read-report window exists purely to hand back finished ids.
            // Answering `no_work` lets the reader close it rather than idling.
            if (!state.link.readReport) {
                await drainPendingDeletes(session, state.link);
                await luna.exports.deliverQueued();
            }
            await concludeWindow(session, state.link);
        } catch (error) {
            luna.log("rendezvous failed", { message: String(error && error.message) });
        } finally {
            activeLink = null;
        }
    },

    async onAction(input) {
        const key = input && input.key;
        if (key === "pair") { return pairReader(); }
        if (key === "unpair") { return unpairReader(); }
    },

    async onSettingsChanged(changes) {
        if (changes && changes.enabled === false) {
            await luna.settings.set("_status", "off");
        }
    },
});

/// Concluding the window is unconditional. After everything the sweep could
/// do, even when some of it failed, the reader must be released rather than
/// left hanging until its idle cap.
async function concludeWindow(session, link) {
    try {
        await control(session, link, "no_work", {});
    } catch (error) {
        luna.log("no_work not delivered", { message: String(error && error.message) });
    }
}

/// A `start_put` answered with `exists` counts as delivered: the reader
/// refuses to overwrite a file already in /Books, so the book IS on the device
/// and a retry could only fail the same way. A missing pairing secret defers
/// instead — pairing is setup, not a failed send.
function exportFailure(error, fileName) {
    const code = (error && error.code) || "";
    const message = String((error && error.message) || "");
    if (message === "exists" || message.indexOf("exists") === 0) {
        return { status: "sent" };
    }
    if (code === "pairing-required" || code === "disconnected" || code === "background") {
        return { status: "retry", message: message };
    }
    luna.log("send failed", { file: fileName, message: message });
    return { status: "failed", message: message };
}

/// Records the exact name that went on the wire, so a later in-app finish can
/// target the same remote file for removal.
async function recordDelivery(saveID, fileName) {
    if (!saveID) { return; }
    await luna.storage.collection("deliveries").put(
        String(saveID), { remoteName: fileName, at: Date.now() });
}

/// First-use pairing. The system picker bonds the reader over BLE, and the
/// hello that follows carries a fresh secret and no shared code — the bonded,
/// encrypted link is the proof of physical presence.
async function pairReader() {
    const device = await luna.bluetooth.pair();
    if (!device) { return; }
    const secret = hexOfBase64(await luna.crypto.randomBytes(32));
    const session = await luna.bluetooth.connect(device.id, { timeout: 20 });
    const state = await openLink(session);
    await control(session, state.link, "hello", { host_id: HOST_ID, pair_secret: secret });
    await luna.secrets.set("pairingSecret", secret);
    await luna.settings.set("enabled", true);
    await session.disconnect();
}

/// Unpair clears the secret and the authorization on both sides, so a later
/// re-pair starts clean.
async function unpairReader() {
    const confirmed = await luna.ui.confirm({
        title: "Unpair the reader?",
        message: "Luna stops delivering saved articles to it.",
        ok: "Unpair", destructive: true,
    });
    if (!confirmed) { return; }
    for (const device of await luna.bluetooth.pairedDevices()) {
        await luna.bluetooth.unpair(device.id);
    }
    await luna.secrets.delete("pairingSecret");
    await luna.settings.set("enabled", false);
    await luna.settings.set("_status", "off");
}
