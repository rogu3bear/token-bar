import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const read = (path) =>
  readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("changelog.json is generated from CHANGELOG.md", async () => {
  const changelogJson = JSON.parse(await read("public/changelog.json"));
  assert.ok(changelogJson.generated, "changelog.json should have a generated timestamp");
  assert.ok(Array.isArray(changelogJson.releases), "changelog.json should have a releases array");
  assert.ok(changelogJson.releases.length > 0, "changelog.json should have at least one release");
});

test("latest CHANGELOG.md version matches the first release in changelog.json", async () => {
  const changelogMd = await read("../CHANGELOG.md");
  const changelogJson = JSON.parse(await read("public/changelog.json"));
  
  // Extract first version from CHANGELOG.md (## X.Y.Z — Released ...)
  const firstVersionMatch = changelogMd.match(/^##\s+([\d.]+)\s+—\s+Released\s+([\d-]+)/m);
  assert.ok(firstVersionMatch, "CHANGELOG.md should have at least one release");
  
  const mdVersion = firstVersionMatch[1];
  const jsonVersion = changelogJson.releases[0].version;
  
  assert.equal(jsonVersion, mdVersion, 
    `changelog.json first release (${jsonVersion}) should match CHANGELOG.md first version (${mdVersion})`);
});

test("release.json version appears in changelog", async () => {
  const releaseJson = JSON.parse(await read("public/release.json"));
  const changelogJson = JSON.parse(await read("public/changelog.json"));
  
  const releaseVersion = releaseJson.version;
  const changelogVersions = changelogJson.releases.map(r => r.version);
  
  assert.ok(changelogVersions.includes(releaseVersion),
    `release.json version ${releaseVersion} should appear in changelog`);
});

test("all changelog releases have required fields", async () => {
  const changelogJson = JSON.parse(await read("public/changelog.json"));
  
  for (const release of changelogJson.releases) {
    assert.ok(release.version, "each release should have a version");
    assert.match(release.version, /^\d+\.\d+\.\d+$/, 
      `version ${release.version} should match major.minor.patch format`);
    
    assert.ok(release.date, "each release should have a date");
    assert.ok(release.notes, "each release should have notes");
  }
});

test("changelog versions are in descending order", async () => {
  const changelogJson = JSON.parse(await read("public/changelog.json"));
  
  for (let i = 0; i < changelogJson.releases.length - 1; i++) {
    const current = changelogJson.releases[i].version.split('.').map(Number);
    const next = changelogJson.releases[i + 1].version.split('.').map(Number);
    
    // Compare version numbers: current should be >= next
    const currentIsNewer = 
      current[0] > next[0] ||
      (current[0] === next[0] && current[1] > next[1]) ||
      (current[0] === next[0] && current[1] === next[1] && current[2] > next[2]);
    
    assert.ok(currentIsNewer,
      `versions should be in descending order: ${changelogJson.releases[i].version} should be > ${changelogJson.releases[i + 1].version}`);
  }
});

test("changelog page loads its data and styles under the site's self-only CSP", async () => {
  const changelogHtml = await read("public/changelog/index.html");
  const changelogScript = await read("public/changelog.js");
  assert.match(changelogHtml, /src="\/changelog\.js/);
  assert.match(changelogHtml, /href="\/changelog\.css/);
  assert.doesNotMatch(changelogHtml, /<script(?![^>]*\bsrc=)|<style[\s>]/);
  assert.match(changelogScript, /\/changelog\.json/,
    "changelog renderer should reference changelog.json");
  assert.match(changelogHtml, /<h1>Changelog<\/h1>/, 
    "changelog page should have a Changelog heading");
});
