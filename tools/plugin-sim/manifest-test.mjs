import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { manifestErrors, matchesURL } from "./manifest.mjs";

const cases = JSON.parse(readFileSync(new URL("../../LunaTests/Fixtures/Plugins/manifest-cases.json", import.meta.url), "utf8"));
for (const fixture of cases) {
  const errors = manifestErrors(fixture.manifest);
  assert.equal(errors.length === 0, fixture.valid, `${fixture.name}: ${errors.join("; ")}`);
}
const wildcard = { match: { hosts: ["*.EXAMPLE.COM"] } };
for (const url of ["https://example.com", "https://www.example.com", "https://a.b.example.com"])
  assert.equal(matchesURL(wildcard, url), true, url);
for (const url of ["https://notexample.com", "https://example.com.evil.org", "bad URL"])
  assert.equal(matchesURL(wildcard, url), false, url);
console.log(`${cases.length} shared manifest cases passed`);
