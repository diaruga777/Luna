// Authoring validation. Limits and enum values come from the native rules;
// shared acceptance fixtures pin the behavior to PluginManifestParser.
import { readFileSync } from "node:fs";

export const rules = JSON.parse(readFileSync(new URL(
  "../../LunaLibraries/Sources/LunaPluginKit/Resources/PluginManifestRules.json", import.meta.url), "utf8"));
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const present = (value, key) => Object.hasOwn(value, key);
const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });
const length = (text) => Array.from(graphemes.segment(text)).length;

export function parseHeader(source) {
  if (Buffer.byteLength(source, "utf8") > rules.source.maxKB * 1024)
    throw new Error(`source exceeds ${rules.source.maxKB} KB`);
  const opening = source.match(/^\s*\/\*/);
  if (!opening) throw new Error("no /* luna-plugin ... */ header at the top of the file");
  const close = source.indexOf("*/", opening[0].length);
  if (close < 0) throw new Error("the plugin header comment is not closed");
  const lines = source.slice(opening[0].length, close).split("\n");
  if (lines.shift().trim() !== "luna-plugin")
    throw new Error("the first header line must be exactly luna-plugin");
  try { return JSON.parse(lines.join("\n")); }
  catch (error) { throw new Error(`manifest JSON is invalid: ${error.message}`); }
}

export function manifestErrors(manifest) {
  const errors = [];
  const fail = (field, message) => errors.push(`${field}: ${message}`);
  const boolean = (value, key, field = key) => {
    if (present(value, key) && typeof value[key] !== "boolean") fail(field, "must be true or false");
  };
  const localized = (value, field, max, nonEmpty = true) => {
    const table = typeof value === "string" ? { en: value } : value;
    if (!object(table) || !present(table, "en")) {
      fail(field, "must be a string or localized object with en"); return;
    }
    for (const text of Object.values(table)) {
      if (typeof text !== "string" || (nonEmpty && !text.trim())) {
        fail(field, "every variant must be a non-empty string"); break;
      }
      if (max && length(text) > max) { fail(field, `must be at most ${max} characters`); break; }
    }
  };
  const list = (value, field, allowed, nonEmpty = true) => {
    if (!Array.isArray(value) || (nonEmpty && !value.length)
        || value.some((item) => typeof item !== "string" || (allowed && !allowed.includes(item)))) {
      fail(field, "must be a list of supported strings" + (nonEmpty ? " with at least one entry" : "")); return false;
    }
    return true;
  };
  if (!object(manifest)) return ["manifest must be a JSON object"];
  if (typeof manifest.id !== "string" || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)*$/.test(manifest.id)
      || manifest.id.length > rules.id.maxLength) fail("id", "must use lowercase letters, digits, dots and hyphens without empty segments (maximum 100 characters)");
  localized(manifest.name, "name", rules.name.maxLength);
  if (present(manifest, "description")) localized(manifest.description, "description", rules.description.maxLength);
  if (typeof manifest.version !== "string" || manifest.version.length > rules.version.maxLength
      || !new RegExp(rules.version.pattern).test(manifest.version)) fail("version", "must look like 1.0.0");
  if (manifest.api !== rules.api.current) fail("api", `must be ${rules.api.current}`);
  if (present(manifest, "priority") && !Number.isSafeInteger(manifest.priority)) fail("priority", "must be a whole number");
  boolean(manifest, "background");
  if (present(manifest, "capabilities")) list(Array.isArray(manifest.capabilities)
    ? manifest.capabilities.map((name) => typeof name === "string" ? name.trim() : name)
    : manifest.capabilities, "capabilities", rules.capabilities, false);
  if (present(manifest, "produces")) list(manifest.produces, "produces", rules.kinds);
  if (present(manifest, "match")) {
    const match = manifest.match;
    if (!object(match)) fail("match", "must be an object");
    else {
      boolean(match, "any", "match.any");
      if (present(match, "hosts") && list(match.hosts, "match.hosts", null, false)) {
        for (const raw of match.hosts) {
          const host = raw.trim().toLowerCase();
          const plain = host.startsWith("*.") ? host.slice(2) : host;
          if (!plain || /[\s/*:#?@]/.test(plain) || plain.startsWith(".") || plain.endsWith(".") || plain.includes(".."))
            fail("match.hosts", `invalid host pattern ${JSON.stringify(raw)}; use example.com, *.example.com, or any: true`);
        }
      }
      if (match.any !== true && !match.hosts?.length) fail("match", "list hosts or set any: true");
    }
  } else if (manifest.produces?.length) fail("match", "is required for an ingest plugin");

  const settingsKeys = new Set();
  if (present(manifest, "settings")) {
    if (!Array.isArray(manifest.settings)) fail("settings", "must be an array");
    else for (const field of manifest.settings) {
      if (!object(field)) { fail("settings", "each field must be an object"); continue; }
      if (typeof field.key !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_]*$/.test(field.key)) fail("settings.key", "use ASCII letters, digits and underscores; no leading underscore");
      if (settingsKeys.has(field.key)) fail("settings.key", `${field.key} is listed twice`);
      settingsKeys.add(field.key);
      if (!rules.settingTypes.includes(field.type)) fail("settings.type", "is not a supported type");
      localized(field.label, "settings.label");
      for (const key of ["help", "placeholder"]) if (present(field, key)) localized(field[key], `settings.${key}`, null, false);
      boolean(field, "required", "settings.required");
      boolean(field, "secret", "settings.secret");
      if (field.type === "choice") {
        if (!Array.isArray(field.options) || !field.options.length) fail("settings.options", "choice needs a non-empty options array");
        else for (const option of field.options) {
          if (!object(option)) { fail("settings.options", "each option must be an object"); continue; }
          if (typeof option.id !== "string" || !option.id.length) fail("settings.options.id", "must be a non-empty string");
          localized(option.label, "settings.options.label");
        }
      }
    }
  }
  if (present(manifest, "export")) {
    const exp = manifest.export;
    if (!object(exp)) fail("export", "must be an object");
    else {
      const validKinds = list(exp.kinds, "export.kinds", rules.kinds);
      if (!rules.exportInputFormats.includes(exp.input)) fail("export.input", "is not supported");
      else if (validKinds && exp.kinds.some((kind) => !rules.exportInputsByKind[kind].includes(exp.input)))
        fail("export.input", `${exp.input} cannot be produced for every declared kind`);
      localized(exp.title, "export.title", 40);
      boolean(exp, "destination", "export.destination");
      boolean(exp, "dequeueOnRead", "export.dequeueOnRead");
      if (present(exp, "requiresSettings") && list(exp.requiresSettings, "export.requiresSettings", null, false))
        for (const key of exp.requiresSettings) if (!settingsKeys.has(key)) fail("export.requiresSettings", `${key} is not a declared setting`);
      if (present(exp, "inputOptions")) {
        if (!object(exp.inputOptions)) fail("export.inputOptions", "must be an object");
        else if (present(exp.inputOptions, "epub")) {
          const epub = exp.inputOptions.epub;
          if (!object(epub)) fail("export.inputOptions.epub", "must be an object");
          else {
            if (present(epub, "profile") && !["standard", "compact"].includes(epub.profile)) fail("export.inputOptions.epub.profile", "must be standard or compact");
            boolean(epub, "images", "export.inputOptions.epub.images");
          }
        }
      }
    }
  }
  if (present(manifest, "bluetooth")) {
    const bt = manifest.bluetooth;
    if (!object(bt)) fail("bluetooth", "must be an object");
    else {
      if (!Array.isArray(manifest.capabilities) || !manifest.capabilities.some((name) => typeof name === "string" && name.trim() === "bluetooth")) fail("bluetooth", "requires the bluetooth capability");
      list(bt.services, "bluetooth.services", null);
      if (present(bt, "pairing") && !["none", "accessorySetupKit"].includes(bt.pairing)) fail("bluetooth.pairing", "must be none or accessorySetupKit");
      boolean(bt, "standingConnect", "bluetooth.standingConnect");
    }
  }
  return errors;
}

export function matchesURL(manifest, url) {
  let host;
  try { host = new URL(url).hostname.toLowerCase(); } catch { return false; }
  if (manifest.match?.any) return true;
  return (manifest.match?.hosts || []).some((pattern) => {
    pattern = pattern.trim().toLowerCase();
    return pattern.startsWith("*.") ? (host === pattern.slice(2) || host.endsWith(pattern.slice(1))) : host === pattern;
  });
}
