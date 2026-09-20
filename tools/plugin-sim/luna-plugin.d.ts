// luna-plugin.d.ts
//
// Typings for the `luna.*` bridge (claudedocs/plans/plugin-platform.md §3–§6).
// Shipped with the authoring docs (`docs/plugins/`) so a plugin author's
// editor checks a plugin file against the real contract. Kept in sync with
// the three backings (SwiftSoup, `plugin_host.js`'s DOMParser, this
// package's `linkedom`) by hand — a bridge change updates this file in the
// same commit.

// ---------------------------------------------------------------- Manifest

export type PluginModelKind = "article" | "media" | "product";

/// A user-visible manifest field's value (§2.2 of `claudedocs/plugins.md`):
/// a plain string, or a table keyed by BCP-47 language tag that MUST
/// include `"en"`. Luna resolves this to one `string` at import time —
/// `luna.localize` applies the identical rule to a table your own code
/// builds at runtime.
export type LocalizedText = string | Record<string, string>;

export type PluginCapabilityName =
  | "fetch" | "html" | "page" | "storage" | "secrets" | "files" | "crypto"
  | "browser" | "downloads" | "settings" | "ui" | "mail" | "notifications"
  | "bluetooth" | "wifi" | "exports";

export interface ExportInputOptions {
  epub?: { images?: boolean; profile?: "standard" | "compact" };
}

export type ExportInputFormat =
  | "url" | "epub" | "pdf" | "docx" | "markdown" | "text" | "html" | "json" | "file";

export interface ExportDeclaration {
  kinds: PluginModelKind[];
  input: ExportInputFormat;
  inputOptions?: ExportInputOptions;
  title: LocalizedText;
  symbol?: string;
  destination?: boolean;
  requiresSettings?: string[];
  // The receiver tracks reading of its own, so Luna drops a queued send whose
  // save was finished in Luna before the send went out.
  dequeueOnRead?: boolean;
}

export interface SettingOption { id: string; label: LocalizedText }

export interface SettingField {
  key: string;
  type: "text" | "email" | "url" | "password" | "number" | "toggle" | "choice"
    | "pairedDevice" | "action" | "info";
  label: LocalizedText;
  help?: LocalizedText;
  placeholder?: LocalizedText;
  options?: SettingOption[];
  default?: unknown;
  required?: boolean;
  secret?: boolean;
}

export interface BluetoothDeclaration {
  services: string[];
  pairing: "accessorySetupKit" | "none";
  standingConnect?: boolean;
  role: "central";
}

export interface PluginManifest {
  id: string;
  name: LocalizedText;
  version: string;
  api: 1;
  description?: LocalizedText;
  produces?: PluginModelKind[];
  match?: { hosts?: string[]; any?: boolean };
  priority?: number;
  capabilities?: PluginCapabilityName[];
  export?: ExportDeclaration;
  settings?: SettingField[];
  bluetooth?: BluetoothDeclaration;
  background?: boolean;
}

// -------------------------------------------------------------------- Hooks

export interface PageSnapshot {
  url: string;
  html?: string;
  title?: string;
  source: "safari" | "fetch" | "browser";
  /** True when Luna bounded the supplied HTML to 200,000 characters. */
  truncated?: boolean;
}

/**
 * What the user asked for, when they asked for something other than a plain
 * save. `"transcribe"` is set by the app's Transcribe actions only: a plugin
 * that would store the media declines it, so the walk reaches the plugin that
 * reads it as an article. Absent (not null) on a plain save, in the share and
 * action extensions, and in Safari.
 */
export type IngestIntent = "transcribe";

export interface ClassifyInput {
  url: string;
  page?: PageSnapshot;
  context: "app" | "share" | "action" | "safari";
  intent?: IngestIntent;
}

export type ClassifyResult =
  | false
  | { kind: PluginModelKind; itemId?: string; confidence?: number };

export interface IngestInput {
  url: string;
  claim: { kind: PluginModelKind; itemId?: string };
  page?: PageSnapshot;
  reason: "save" | "resume" | "refresh" | "reresolve" | "rescue";
  context: "app" | "share" | "action" | "safari";
  saveId?: string;
  intent?: IngestIntent;
}

export interface ExportInput {
  kind: PluginModelKind;
  saveId: string;
  url: string;
  title: string;
  format: ExportInputFormat;
  file?: FileHandle;
  text?: string;
  json?: unknown;
  auto: boolean;
  source?: string;
  queuedRemaining?: number;
}

export type ExportResult =
  | null
  | { file: FileHandle; name?: string; mime?: string }
  | { text: string; name?: string; mime?: string }
  | { url: string }
  | {
      status: "sent" | "failed" | "retry";
      message?: string;
      hard?: boolean;
      // The name the receiving device filed the save under. Report it and
      // Luna can name that exact file in a later delete.
      remoteName?: string;
    };

export interface BluetoothDevice { id: string; name?: string; serviceUUIDs: string[] }

export type BluetoothEvent =
  | { type: "connected"; device: BluetoothDevice; restored: boolean }
  | { type: "disconnected"; device: BluetoothDevice; error?: string }
  | { type: "paired"; device: BluetoothDevice }
  | { type: "unpaired"; device: BluetoothDevice }
  | { type: "stateChanged"; state: "poweredOn" | "poweredOff" | "unauthorized" | "unsupported" };

export interface BluetoothSession {
  readonly device: BluetoothDevice;
  readonly mtu: number;
  discover(serviceUUID: string): Promise<{ characteristics: string[] }>;
  read(characteristicUUID: string): Promise<string>;
  write(characteristicUUID: string, base64: string, opts?: { response?: boolean }): Promise<void>;
  subscribe(characteristicUUID: string): Promise<void>;
  next(characteristicUUID: string, opts?: { timeout?: number }): Promise<string>;
  disconnect(): Promise<void>;
}

export interface PluginHooks {
  classify?(input: ClassifyInput): ClassifyResult | Promise<ClassifyResult>;
  ingest?(input: IngestInput): Promise<PluginModel | null>;
  export?(input: ExportInput): Promise<ExportResult>;
  // A hook is called with exactly one JSON argument (the runtime does
  // `JSON.parse` on an encoded string and calls the hook with that one
  // value) — a native session object cannot ride along as a second
  // parameter. Read the live session with `luna.bluetooth.session()`
  // instead; it stays live for the whole invocation, including a nested
  // `export` call `luna.exports.deliverQueued()` triggers.
  onBluetooth?(event: BluetoothEvent): Promise<void>;
  onSettingsChanged?(changes: Record<string, unknown>): Promise<void>;
  // Same one-argument rule: the settings screen and `PluginDetailScreen`
  // both call this with an object, never a bare string. A `pairedDevice` row
  // adds `action`, because one row offers Pair and Unpair under one key.
  onAction?(input: { key: string; action?: "pair" | "unpair" }): Promise<void>;
}

// ------------------------------------------------------------------- Models

export interface MediaAssetSpec {
  url: string;
  type: "video" | "image" | "gif" | "audio";
  audioURL?: string;
  dashManifestURL?: string;
  thumbnailURL?: string;
  estimatedBytes?: number;
  headers?: Record<string, string>;
  timeRange?: { start: number; end: number };
  quality?: string;
}

export interface MediaModel {
  kind: "media";
  title?: string;
  author?: string;
  thumbnailURL?: string;
  platform?: string;
  itemId?: string;
  assets: MediaAssetSpec[];
  expiresAt?: number;
}

export interface ArticleDocumentSpec {
  url: string;
  type: "pdf" | "epub" | "docx" | "rtf" | "html" | "md" | "txt";
  headers?: Record<string, string>;
}

/**
 * An audio or video file Luna downloads, transcribes on device into the
 * article's body, and deletes. `audioURL` names a separate audio leg for a
 * video; when present ONLY that leg is fetched. `expiresAt` is epoch seconds;
 * a stale URL makes Luna re-run `ingest` with `reason: "reresolve"` first.
 */
export interface ArticleTranscriptionSpec {
  url: string;
  type: "audio" | "video";
  audioURL?: string;
  headers?: Record<string, string>;
  expiresAt?: number;
}

export interface ArticleModel {
  kind: "article";
  title: string;
  author?: string;
  publishedAt?: string;
  /** Required unless `transcription` is set; with it, optional text that
   *  PRECEDES the transcript (a description, the post's own words). */
  html?: string;
  baseURL?: string;
  leadImageURL?: string;
  excerpt?: string;
  language?: string;
  /** Cannot be combined with `transcription`. */
  document?: ArticleDocumentSpec;
  transcription?: ArticleTranscriptionSpec;
}

export interface Price { amount: string; currency: string }

export interface ProductIdentifiers { gtin?: string; mpn?: string; sku?: string; brand?: string }

export interface ProductSeller { url: string; name?: string; price?: Price }

export interface ProductModel {
  kind: "product";
  name: string;
  price: Price;
  imageURL?: string;
  brand?: string;
  productId?: string;
  identifiers?: ProductIdentifiers;
  sellers?: ProductSeller[];
}

export type PluginModel = MediaModel | ArticleModel | ProductModel;

// -------------------------------------------------------------------- luna.*

export interface ParsedURLSearchParams {
  get(key: string): string | null;
  getAll(key: string): string[];
  has(key: string): boolean;
  entries(): [string, string][];
}

export interface ParsedURL {
  href: string; protocol: string; host: string; hostname: string; port: string;
  pathname: string; search: string; hash: string; searchParams: ParsedURLSearchParams;
}

export class LunaErrorType extends Error {
  /// `(code, message, details)` — the code comes FIRST, in every backing.
  constructor(code: string, message?: string, details?: unknown);
  code: string;
  details?: unknown;
}

// ---- luna.html (§6.3 — the exact subset every backing agrees on) ----

export interface HTMLElement {
  querySelector(css: string): HTMLElement | null;
  querySelectorAll(css: string): HTMLElement[];
  readonly textContent: string;
  readonly innerHTML: string;
  readonly outerHTML: string;
  readonly children: HTMLElement[];
  readonly parentElement: HTMLElement | null;
  readonly tagName: string;
  getAttribute(name: string): string | null;
  hasAttribute(name: string): boolean;
  readonly attributes: Record<string, string>;
  matches(css: string): boolean;
  closest(css: string): HTMLElement | null;
  readonly baseURI: string;
  absoluteURL(attr: string): string | null;
}

export interface HTMLDocument extends HTMLElement {
  readonly title: string;
  readonly documentElement: HTMLElement;
  readonly body: HTMLElement | null;
  readonly head: HTMLElement | null;
}

/// What the page says about itself, read out of OpenGraph, Twitter cards,
/// plain `<meta name>`, `<link rel=canonical>`, `<title>`, `<html lang>` and
/// JSON-LD, in that order per key. A key no source states is absent.
/// `image` and `canonical` are already absolute.
export interface PageMetadata {
  title?: string; description?: string; canonical?: string; image?: string;
  author?: string; published?: string; siteName?: string; language?: string;
  type?: string;
}

/// Luna's own main-content extraction. `html` carries only the tags an
/// `ArticleModel` keeps.
export interface ExtractedArticle {
  title: string; html: string; text: string;
  author?: string; publishedAt?: string; leadImageURL?: string; excerpt?: string;
}

export interface LunaHTML {
  parse(html: string, baseURL?: string): HTMLDocument;
  text(html: string): string;
  jsonScripts(doc: HTMLDocument, type?: string): unknown[];
  /// Every `<script type="application/ld+json">`, `@graph` flattened one
  /// level and bad JSON skipped. Always an array.
  jsonLD(doc: HTMLDocument): Record<string, unknown>[];
  meta(doc: HTMLDocument): PageMetadata;
  /// A Promise in EVERY process: Safari has no readability pass of its own
  /// and relays the call to Luna, so the shape cannot be synchronous there.
  /// `null` when the page has no article body.
  article(html: string, baseURL?: string): Promise<ExtractedArticle | null>;
}

// ---- luna.text (rides on the `html` capability) ----

export interface ParsedPrice {
  /// Digits and at most one dot, keeping the fraction digits the page wrote.
  amount: string;
  /// ISO 4217, when a symbol or a code touches the number.
  currency?: string;
}

export interface LunaText {
  price(s: string): ParsedPrice | null;
  /// An absolute date as ISO 8601 — `2024-03-04T09:30:00Z` when the string
  /// carried a time, `2024-03-04` when it did not. A relative phrase is null.
  date(s: string): string | null;
  /// Entities decoded, tags dropped, whitespace collapsed, trimmed.
  clean(s: string): string;
}

// ---- luna.fetch (§6.2) ----

// A part carries text, base64 or a `FileHandle`. `file` reads the bytes off
// disk, so a downloaded or exported file uploads without a base64 round trip;
// `filename` and `mime` default to the handle's own. It needs the `files`
// capability, so it works in the app and the share/action extensions, never in
// Safari. A handle whose scratch generation is gone rejects `not-found` before
// the request leaves, and one over 8 MB rejects `too-large`.
export interface MultipartPart {
  name: string; filename?: string; mime?: string;
  text?: string; base64?: string; file?: FileHandle;
}

export interface FetchRequest {
  url: string;
  method?: "GET" | "POST" | "HEAD" | "PUT";
  headers?: Record<string, string>;
  userAgent?: "safari" | "googlebot" | "googlebot-mobile" | "bingbot" | "facebookbot" | string;
  body?: string | { base64: string } | { form: Record<string, string> } | { json: unknown }
    | { multipart: MultipartPart[] };
  // A page's own session is not a policy: read `cookieHeader` off the browser
  // result and set the header. Any other value rejects `bad-argument`.
  cookies?: "shared" | "ephemeral" | "none";
  redirect?: "follow" | "manual" | "headThenGet";
  maxBytes?: number;
  timeout?: number;
  as?: "text" | "base64" | "file";
}

export interface FileHandle { readonly id: string; readonly name: string; readonly size: number; readonly mime?: string }

export interface FetchResponse {
  ok: boolean; status: number; url: string; redirected: boolean;
  headers: Record<string, string>; text?: string; base64?: string; file?: FileHandle;
  truncated: boolean; bytes: number;
}

/// `luna.fetch` is a function that also carries three helpers. Each is a GET
/// whose `opts` are the ordinary request minus `url`, and each rejects
/// `fetch-failed` — with the status in the message — on a non-2xx answer.
export interface LunaFetch {
  (request: string | FetchRequest): Promise<FetchResponse>;
  text(url: string, opts?: Omit<FetchRequest, "url">): Promise<string>;
  /// A body that is not JSON rejects `fetch-failed` too.
  json(url: string, opts?: Omit<FetchRequest, "url">): Promise<unknown>;
  /// `luna.html.parse` over the body, with the base set to the FINAL URL.
  /// Needs the `html` capability as well; without it, rejects
  /// `capability-not-declared`.
  doc(url: string, opts?: Omit<FetchRequest, "url">): Promise<HTMLDocument>;
}

// ---- luna.storage (§6.5) ----

export interface CollectionQuery { k1?: string; k2?: string }
export interface CollectionIndex { k1?: string; k2?: string }
export interface CollectionOpts { limit?: number; offset?: number }
export interface CollectionRow { id: string; doc: object }

export interface Collection {
  put(id: string, doc: object, index?: CollectionIndex): Promise<void>;
  get(id: string): Promise<object | undefined>;
  delete(id: string): Promise<void>;
  find(where?: CollectionQuery, opts?: CollectionOpts): Promise<CollectionRow[]>;
  count(where?: CollectionQuery): Promise<number>;
}

export interface Storage {
  // `undefined` for a key that holds nothing; `null` is a value a plugin may
  // have stored on purpose.
  get(key: string): Promise<unknown | undefined>;
  set(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<void>;
  keys(prefix?: string): Promise<string[]>;
  collection(name: string): Collection;
}

// ---- luna.browser (§6.10 — app only; Safari and extensions always defer) ----

export interface BrowserRequest {
  url: string;
  // Which save the browser step belongs to. Only needed when the plugin has
  // several `ingest` calls in flight at once, and rejects `bad-argument`
  // otherwise.
  saveId?: string;
  userAgent?: "device-safari" | string;
  headers?: Record<string, string>;
  cookies?: "persistent" | "ephemeral";
  detect: string;
  title?: string;
  timeout?: number;
}

export interface BrowserResult {
  url: string; html: string; title: string; cookieHeader: string;
  cookies: { name: string; value: string; domain: string }[];
}

// ---- luna.settings (§6.11) ----

export interface Settings {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
  all(): Promise<Record<string, unknown>>;
}

// ---- luna.crypto (§6.8) ----

export interface Crypto {
  sha256(data: string | { base64: string }): Promise<string>;
  hmacSHA256(key: { base64: string } | string, data: string | { base64: string }): Promise<string>;
  randomBytes(count: number): Promise<string>;
}

// ---- luna.downloads (§6.9 — app/share/action only, read only) ----
// Read-only view of the download engine's own live media download jobs.
// `phase` is `LiveMediaDownloadJob.Phase`'s own raw values, not the design's
// original `queued`/`deferredUntilWiFi` names — those never named a real
// engine state. Absent in Safari; a non-UUID `saveId` rejects `bad-argument`.

export interface DownloadJob {
  saveId: string | null; sourceUrl: string; title: string;
  phase: "resolving" | "downloading" | "waiting" | "suspended" | "saving" | "finished" | "failed";
  progress: number; receivedBytes: number | null; expectedBytes: number | null;
  failure: string | null; pluginId: string | null; quality: string | null;
}

export interface Downloads {
  jobs(): Promise<DownloadJob[]>;
  job(saveId: string): Promise<DownloadJob | null>;
}

// ---- luna.ui (§6.12 — app only) ----

export interface UI {
  prompt(opts: {
    title: string; message?: string; placeholder?: string;
    keyboard?: "default" | "email" | "url" | "number"; secure?: boolean; default?: string;
  }): Promise<string | null>;
  confirm(opts: { title: string; message?: string; ok?: string; cancel?: string; destructive?: boolean }): Promise<boolean>;
  choose(opts: { title: string; options: { id: string; label: string; detail?: string }[] }): Promise<string | null>;
  toast(message: string): Promise<void>;
  shareSheet(items: (FileHandle | { url: string } | { text: string })[]): Promise<void>;
}

// ---- luna.mail (§6.13 — app only) ----

export interface MailMessage {
  to?: string[]; subject: string; text?: string; html?: string;
  attachments?: { file: FileHandle; name?: string; mime?: string }[];
}

export interface Mail {
  send(message: MailMessage): Promise<{ status: "sent" }>;
  isConfigured(): Promise<boolean>;
}

// ---- luna.notifications (§6.14 — app only) ----

export interface Notifications {
  post(n: { title: string; body?: string; identifier?: string; deepLink?: string }): Promise<{ posted: boolean }>;
  clear(identifier?: string): Promise<void>;
}

// ---- luna.bluetooth / luna.wifi (§10 — app only) ----

export interface Bluetooth {
  state(): Promise<"poweredOn" | "poweredOff" | "unauthorized" | "unsupported" | "unknown">;
  pair(): Promise<BluetoothDevice | null>;
  pairedDevices(): Promise<BluetoothDevice[]>;
  unpair(deviceId: string): Promise<void>;
  // Rejects with `already-connecting` while an earlier connect to the same
  // device is still waiting for its link; await that one instead.
  connect(deviceId: string, opts?: { timeout?: number }): Promise<BluetoothSession>;
  // Synchronous on purpose: the answer is "is a link live right now", and an
  // awaited call could not tell "no session" from "not yet". Live for the
  // whole `onBluetooth` invocation that is holding the connection.
  session(): BluetoothSession | null;
}

export interface Wifi {
  join(opts: { ssid: string; passphrase?: string; joinOnce?: boolean }): Promise<{ joined: boolean }>;
  forget(ssid: string): Promise<void>;
  isReachable(host: string, port: number, opts?: { timeout?: number }): Promise<boolean>;
}

// ---- luna.exports (§6.16 — destination plugins, app only) ----

export interface Exports {
  deliverQueued(): Promise<{ delivered: number; remaining: number }>;
  // `queuedAt` is absent for a save with no date of its own.
  queued(): Promise<{ saveId: string; title: string; queuedAt?: string }[]>;
  markSent(saveId: string): Promise<void>;
  // Deliveries whose reading finished IN Luna: delete each on the device,
  // then mark it. `remoteName` is what your `export` reported.
  pendingDeletes(): Promise<{ saveId: string; title: string; remoteName: string }[]>;
  markRemoteDeleted(saveId: string): Promise<void>;
  // The DEVICE finished the save. Luna marks it read and files it away, and
  // asks for no delete, since the device already handled it.
  markReadOnDevice(saveId: string): Promise<void>;
}

// ---- luna.page (§6.4 — Safari only) ----

export interface Page {
  document(): HTMLDocument;
  url(): string;
  title(): string;
  /** At most 200,000 characters. */
  html(): string;
  /** Whether html() omitted the tail of the live document. */
  truncated(): boolean;
}

// ---- the frozen `luna` object every plugin body sees ----

export interface Env {
  context: "app" | "share" | "action" | "safari";
  api: 1;
  pluginId: string;
  version: string;
  /// The BCP-47 tag of the first entry in `languages`.
  locale: string;
  /// Preferred language tags, most-preferred first — what `luna.localize`
  /// and the manifest parser resolve a copy table against.
  languages: string[];
}

export interface Bytes {
  fromBase64(s: string): Uint8Array;
  toBase64(b: Uint8Array): string;
  utf8Encode(s: string): Uint8Array;
  utf8Decode(b: Uint8Array): string;
}

/// Every namespace below except `register`/`parseURL`/`log`/`bytes`/`env`/
/// `LunaError` is present ONLY when the manifest declares its capability —
/// an undeclared one is `undefined`, never a stub that throws.
export interface Luna {
  register(hooks: PluginHooks): void;
  parseURL(url: string, base?: string): ParsedURL;
  log(message: string, data?: unknown): void;
  bytes: Bytes;
  env: Env;
  LunaError: typeof LunaErrorType;
  /// Resolves a `LocalizedText` value against `env.languages`, the same
  /// rule the manifest parser applies to `name`/`label`/… (§2.2). A plain
  /// string passes through unchanged.
  localize(table: LocalizedText): string;

  fetch?: LunaFetch;
  html?: LunaHTML;
  /// Installed with `html`; it declares no capability of its own.
  text?: LunaText;
  page?: Page;
  storage?: Storage;
  secrets?: { get(key: string): Promise<string | undefined>; set(key: string, value: string): Promise<void>; delete(key: string): Promise<void> };
  files?: {
    write(name: string, data: string | { base64: string }, mime?: string): Promise<FileHandle>;
    // Without "base64", bytes that are not UTF-8 reject `not-text`.
    read(handle: FileHandle, as: "text" | "base64"): Promise<string>;
    size(handle: FileHandle): Promise<number>;
  };
  crypto?: Crypto;
  browser?: { open(request: BrowserRequest): Promise<BrowserResult> };
  downloads?: Downloads;
  settings?: Settings;
  ui?: UI;
  mail?: Mail;
  notifications?: Notifications;
  bluetooth?: Bluetooth;
  wifi?: Wifi;
  exports?: Exports;
}

declare global {
  const luna: Luna;
}
