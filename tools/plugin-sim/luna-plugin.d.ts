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
  title: string;
  symbol?: string;
  destination?: boolean;
  requiresSettings?: string[];
}

export interface SettingOption { id: string; label: string }

export interface SettingField {
  key: string;
  type: "text" | "email" | "url" | "password" | "number" | "toggle" | "choice"
    | "pairedDevice" | "action" | "info";
  label: string;
  help?: string;
  placeholder?: string;
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
  name: string;
  version: string;
  api: 1;
  description?: string;
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
}

export interface ClassifyInput {
  url: string;
  page?: PageSnapshot;
  context: "app" | "share" | "action" | "safari";
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
  | { status: "sent" | "failed" | "retry"; message?: string; hard?: boolean };

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
  onBluetooth?(event: BluetoothEvent, session: BluetoothSession | null): Promise<void>;
  onSettingsChanged?(changes: Record<string, unknown>): Promise<void>;
  onAction?(key: string): Promise<void>;
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

export interface ArticleModel {
  kind: "article";
  title: string;
  author?: string;
  publishedAt?: string;
  html: string;
  baseURL?: string;
  leadImageURL?: string;
  excerpt?: string;
  language?: string;
  document?: ArticleDocumentSpec;
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

export interface LunaHTML {
  parse(html: string, baseURL?: string): HTMLDocument;
  text(html: string): string;
  jsonScripts(doc: HTMLDocument, type?: string): unknown[];
}

// ---- luna.fetch (§6.2) ----

export interface MultipartPart { name: string; filename?: string; mime?: string; text?: string; base64?: string }

export interface FetchRequest {
  url: string;
  method?: "GET" | "POST" | "HEAD" | "PUT";
  headers?: Record<string, string>;
  userAgent?: "safari" | "googlebot" | "googlebot-mobile" | "bingbot" | "facebookbot" | string;
  body?: string | { base64: string } | { form: Record<string, string> } | { json: unknown }
    | { multipart: MultipartPart[] };
  cookies?: "shared" | "ephemeral" | "none" | "browser";
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
  get(key: string): Promise<unknown | undefined>;
  set(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<void>;
  keys(prefix?: string): Promise<string[]>;
  collection(name: string): Collection;
}

// ---- luna.browser (§6.10 — app only; Safari and extensions always defer) ----

export interface BrowserRequest {
  url: string;
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

export interface DownloadJob {
  saveId: string; sourceURL: string; title?: string;
  phase: "queued" | "resolving" | "downloading" | "finished" | "failed" | "deferredUntilWiFi";
  progress: number; receivedBytes: number; expectedBytes?: number; failure?: string;
}

export interface Downloads {
  jobs(): Promise<DownloadJob[]>;
  job(saveId: string): Promise<DownloadJob | undefined>;
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
  connect(deviceId: string, opts?: { timeout?: number }): Promise<BluetoothSession>;
}

export interface Wifi {
  join(opts: { ssid: string; passphrase?: string; joinOnce?: boolean }): Promise<{ joined: boolean }>;
  forget(ssid: string): Promise<void>;
  isReachable(host: string, port: number, opts?: { timeout?: number }): Promise<boolean>;
}

// ---- luna.exports (§6.16 — destination plugins, app only) ----

export interface Exports {
  deliverQueued(): Promise<{ delivered: number; remaining: number }>;
  queued(): Promise<{ saveId: string; title: string; queuedAt: string }[]>;
  markSent(saveId: string): Promise<void>;
}

// ---- luna.page (§6.4 — Safari only) ----

export interface Page {
  document(): HTMLDocument;
  url(): string;
  title(): string;
  html(): string;
}

// ---- the frozen `luna` object every plugin body sees ----

export interface Env {
  context: "app" | "share" | "action" | "safari";
  api: 1;
  pluginId: string;
  version: string;
  locale: string;
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

  fetch?(request: string | FetchRequest): Promise<FetchResponse>;
  html?: LunaHTML;
  page?: Page;
  storage?: Storage;
  secrets?: { get(key: string): Promise<string | undefined>; set(key: string, value: string): Promise<void>; delete(key: string): Promise<void> };
  files?: {
    write(name: string, data: string | { base64: string }, mime?: string): Promise<FileHandle>;
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
