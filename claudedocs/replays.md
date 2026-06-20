# Replays (save diagnostics)

A **Replay** records EVERYTHING about ONE save — the initial input + its source,
an ordered list of typed events (every input, output, network request/response,
and pipeline decision), and the final formatted article — so a save can be
exported, replayed, and turned into tests. This doc is the **contract** for the
integration-test harness and the price-tracking feature (both must stay
Replay-compatible).

> **Media bytes are EXCLUDED.** Thumbnails / cover images / video are recorded by
> URL/metadata only — never as bytes. Text bodies (HTML/JSON) are stored verbatim;
> non-media binary as base64. The recorder/fetcher never emit media bytes.

## Key files (all in `ReaderKit/` unless noted)

- `Replay.swift` — the `Codable`, VERSIONED value type (the schema). `Replay`,
  `ReplaySource`, `EventKind`, `NetworkRequest`/`NetworkResponse`, `HTTPBody`.
- `ReplayRecorder.swift` — `ReplayRecording` protocol, the `ReplayRecorder` actor
  (live, `ReplayRecorder.shared`), `NoopReplayRecorder`, `StoredReplay`.
- `ReplayStore.swift` — `ReplayStoring` protocol + `ReplayDiskStore` (zipped
  pretty-JSON in the sandbox **Documents/Replays/**, NOT the App Group).
- `RecordingHTMLFetcher.swift` — a `HTMLFetching` decorator capturing every
  URLSession request/response in `ArticleResolver`/`BypassRunner`.
- `ReplayBugReporter.swift` — marks a save's replay `.userReported` + shares its zip.
- `ZipArchiveWriter.swift` — stored-entry ZIP writer (moved here from `Clip/Send/`;
  shared so extensions can zip exports).
- `Clip/Settings/ReplaysViewController.swift` — the Replays list UI (main app).

## Schema (`schemaVersion = 1`)

`Replay` is a `Codable` value type. Consumers MUST check `schemaVersion` before
decoding `events`/`finalContent`.

```
Replay {
  schemaVersion: Int            // currently 1
  metadata: {
    id: UUID                    // also the export file's base name (<id>.zip / <id>.txt)
    state: ReplayState          // inProgress | failed | success | userReported
    createdAt: ISO8601
    terminatedAt: ISO8601?      // nil while inProgress
    itemURLString: String       // the URL used to list/look up; updated on unwrap
    itemID: UUID?                // the reading-list item this save produced
  }
  input: {
    initialURLString: String     // URL exactly as it entered (pre-unwrap)
    source: ReplaySource         // see below
  }
  events: [Event]                // ordered; `index` is authoritative
  finalContent: ArticleContent?  // the formatted article, present on a readable terminal
}

Event { index: Int; timestamp: ISO8601; kind: EventKind }
```

### `ReplaySource` (a superset of `CaptureSource`)

Internally tagged. Either a standard capture source or a reader-internal one:

```
{"capture": "manual"}     // capture(CaptureSource): paste|shareSheet|appIntent|friendShare|email|manual
{"linkInViewer": {"parentURLString": "https://…"}}  // a link tapped inside another save's viewer
```

`ReplaySource.label` flattens to a string (`"manual"`, `"linkInViewer"`, …).

### `ReplayState` (terminal disposition)

| state | meaning |
|---|---|
| `inProgress` | recording open (rare in a serialized replay — only if the process died mid-save) |
| `failed` | any error, `.failed`, or a genuinely unreadable result |
| `success` | terminal readable UI state (content parsed & ready; unlock done; no further network) |
| `userReported` | user flagged the save buggy from a bug-report entry point |

### `EventKind` (the `type`-discriminated event payload)

Encoded with an internal `"type"` discriminator so consumers branch on `type`.

| `type` | fields | when |
|---|---|---|
| `networkRequest` | `request: NetworkRequest` | an outgoing HTTP request |
| `networkResponse` | `response: NetworkResponse` | an HTTP response (or transport error) |
| `unwrap` | `fromURLString`, `toURLString` | news-aggregator wrapper → publisher URL |
| `resolveDecision` | `outcome: readable\|paywalled\|unreadable` | the resolver's disposition |
| `bypassStrategy` | `name`, `runsSilently: Bool`, `succeeded: Bool` | a silent/WKWebView bypass attempt (`name` = `BypassStrategy.replayName`) |
| `archiveStage` | `stage`, `urlString?`, `note?` | a WKWebView archive/bypass reader stage (`preStage`, `archiveHomepage`, `extracted`, …) |
| `extraction` | `blockCount`, `bodyTextLength`, `title`, `hasReadableBody` | an extraction produced content |
| `stateChange` | `state: ReplayState` | terminal state changed (appended by `terminate`) |
| `mediaReference` | `role`, `urlString` | media recorded by reference only — NO bytes |
| `note` | `text` | free-form diagnostic note |

### `NetworkRequest` / `NetworkResponse`

```
NetworkRequest  { urlString, method, headers: {String:String}, body: HTTPBody? }
NetworkResponse { urlString, statusCode: Int, headers, body: HTTPBody?, error: String? }
```

`statusCode == -1` + non-nil `error` = a transport failure (DNS/timeout/…).

### `HTTPBody` (internally tagged `"kind"`)

```
{"kind":"text","text":"<html…>","truncatedBytes":0}   // verbatim text; truncatedBytes>0 = capped
{"kind":"base64","base64":"…"}                          // non-media binary
{"kind":"omitted","reason":"media: …"}                  // bytes intentionally omitted (media)
```

Text bodies are capped at `ReplayRecorder.maxBodyBytes` (2 MB) per event; the
dropped byte count lands in `truncatedBytes`.

## Example (abbreviated, one readable save)

```json
{
  "schemaVersion": 1,
  "metadata": { "id": "…", "state": "success", "createdAt": "2026-06-20T08:00:00Z",
                "terminatedAt": "2026-06-20T08:00:02Z",
                "itemURLString": "https://example.com/a", "itemID": "…" },
  "input": { "initialURLString": "https://example.com/a", "source": {"capture":"shareSheet"} },
  "events": [
    { "index": 0, "timestamp": "…", "kind": { "type": "networkRequest",
      "request": { "urlString": "https://example.com/a", "method": "GET",
                   "headers": {"User-Agent":"Googlebot|Safari (chain)"}, "body": null } } },
    { "index": 1, "timestamp": "…", "kind": { "type": "networkResponse",
      "response": { "urlString": "https://example.com/a", "statusCode": 200, "headers": {},
                    "body": {"kind":"text","text":"<html>…</html>"}, "error": null } } },
    { "index": 2, "timestamp": "…", "kind": { "type": "resolveDecision", "outcome": "readable" } },
    { "index": 3, "timestamp": "…", "kind": { "type": "extraction",
      "blockCount": 12, "bodyTextLength": 4200, "title": "A", "hasReadableBody": true } },
    { "index": 4, "timestamp": "…", "kind": { "type": "stateChange", "state": "success" } }
  ],
  "finalContent": { "title": "A", "author": null, "blocks": [ … ] }
}
```

## Where files live

`Documents/Replays/` in the **app sandbox** (each process — main app and each
extension — has its own sandbox, so the action/share extensions write their own
replays):

- `<uuid>.zip` — the export. Contains a single stored (uncompressed) entry
  `<uuid>.txt` of pretty-printed, ISO-8601-dated, sorted-keys JSON.
- `index.json` — a lightweight `[{id,itemURLString,state,createdAt}]` so listing
  and by-URL lookup never unzip every export.

`ReplayDiskStore.firstStoredEntryData(inZip:)` reads the JSON back out of a zip
(our writer only ever stores one uncompressed entry, so no inflate is needed).

## Recorder lifecycle & termination

`ReplayRecording` (actor-isolated, async):

- `begin(urlString:source:) -> UUID?` — opens an in-progress replay; the id
  addresses subsequent events. Returns nil when recording is disabled (`Noop`).
- `record(_:for:)` — appends an event (monotonic `index`; oversized text bodies
  capped here).
- `attachItemID(_:to:)` / `updateItemURL(_:for:)` — fill in the item id / repoint
  the URL (after unwrap).
- `terminate(_:state:finalContent:)` — appends a closing `stateChange`, sets
  terminal `state` + `terminatedAt` + `finalContent`, serializes → zips → writes to
  Documents, and DROPS the replay from memory.
- `terminatedReplay(forItemURLString:)` / `markUserReported(forItemURLString:)` /
  `storedReplays()` — lookup + listing for the UI and bug-report.

**Termination conditions** (a replay terminates when the save either):
- **Fails** — any error, `.failed`, `.unreadable` → `.failed`; a `.paywalled`/
  `.unreadable` silent result is `.failed` here because the user still solves the
  archive CAPTCHA in a SEPARATE replay (the archive reader's own).
- **Reaches its terminal readable UI state** — content parsed & ready (`.ready`,
  unlock done, no further network) → `.success` with `finalContent`.

Memory: only IN-PROGRESS replays live in memory, for the duration of one save;
nothing accumulates across saves.

## Instrumentation points (what feeds the recorder)

| Entry point | File | What it records |
|---|---|---|
| Background ingest (paste / manual / **all app intents** via `handleSavePress`) | `Clip/ReadingList/ReadingListIngestor.swift` `ingest` | begin; `unwrap`; wraps the resolver fetcher with `RecordingHTMLFetcher`; `resolveDecision`; `extraction`; terminate on outcome; non-article items (`youtube`/`platform`/`document`) record a note + thumbnail `mediaReference` and terminate |
| Silent bypass loop | `ReaderKit/ArticleResolver.swift` `resolve(…, replayLog:)` | `bypassStrategy` per silent strategy (name + succeeded) |
| Every URLSession fetch | `ReaderKit/RecordingHTMLFetcher.swift` | `networkRequest` + `networkResponse` (HTML body verbatim; error on failure) |
| Share / action extension inline ingest | `ShareKit/ShareViewController.swift` `ingestArticleThenComplete` | begin; wrapped fetcher; `resolveDecision`/`extraction`; terminate |
| Interactive archive / bypass WKWebView | `ReaderKit/ArchiveWebReaderViewController.swift` | begin; `archiveStage` (loaded URLs / homepage / pre-stages / extracted); the extracted WKWebView HTML as a `networkResponse` body; terminate `.success` on extract, `.failed` on terminal message / early exit |

The recorder is injected as a protocol (`ReplayRecording`), so a save with the
`NoopReplayRecorder` (or `begin` returning nil) runs identically with no recording
— recording is never load-bearing.

## UI entry points

- **Diagnostics → Replays** (`Clip/Settings/ReplaysViewController.swift`, opened
  via the "Replays" bar button on `DiagnosticsViewController`): a table listing all
  stored replays **by URL**, an explanatory paragraph at the top ("Replays record
  all data and events for a save and are useful for diagnostics."). Tapping a row
  presents a `UIActivityViewController` exporting that replay's zip. Rows whose
  state is `failed` or `userReported` show a **red warning icon**
  (`exclamationmark.triangle.fill`).
- **Bug report — reader footer**: the end-of-article share footer
  (`ReaderKit/ArticleShareView.swift`) shows a small **ladybug icon to the LEFT of
  the Share button**. Tapping opens a menu with **"Report a bug"** / **"Dismiss"**
  (tapping outside dismisses). "Report a bug" → `ReplayBugReporter.report`.
- **Bug report — reading-list row**: the long-press context menu
  (`Clip/ReadingList/ReadingListViewController.swift` `rowMenu`) has a **"Report a
  bug"** item with the same behavior.

`ReplayBugReporter.report(itemURLString:from:sourceView:)` marks the most recent
terminated replay for that URL `.userReported`, rewrites the export, and shares
its zip; shows an alert if no replay exists.

## Tests

`ClipTests/ReplayTests.swift` — encode/decode round-trip (one of every event
kind), discriminator shapes, source round-trip, recorder event ordering + terminal
state + body capping + `markUserReported`, disk store zip round-trip +
`firstStoredEntryData`, the recording fetcher decorator (success + error) via the
mock fetcher, resolver `bypassStrategy` logging, and media redaction. 13 tests.
