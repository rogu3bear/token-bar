import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const read = (path) =>
  readFile(new URL(`../public/${path}`, import.meta.url), "utf8");
test("unreleased installer cannot be advertised as a signed public download", async () => {
  const release = JSON.parse(await read("release.json"));
  assert.equal(typeof release.available, "boolean");
  if (release.available) {
    assert.match(
      release.url,
      /^https:\/\/github\.com\/rogu3bear\/token-bar\/releases\/download\//,
    );
    assert.match(release.sha256, /^[a-f0-9]{64}$/);
    assert.equal(release.notarized, true);
  }
});
test("function invocations are restricted to API paths", async () => {
  assert.deepEqual(JSON.parse(await read("_routes.json")).include, ["/api/*"]);
});

test('advanced-mode entry keeps feedback, config and static fallback', async () => {
  const { default: worker } = await import('../worker.js');
  let assets = 0;
  const env = { ASSETS: { fetch: async () => { assets++; return new Response('static'); } } };
  const root = await worker.fetch(new Request('https://example.test/'), env);
  assert.equal(await root.text(), 'static'); assert.equal(assets, 1);
  const config = await worker.fetch(new Request('https://example.test/api/config'), env);
  assert.equal((await config.json()).available, false);
  const feedback = await worker.fetch(new Request('https://example.test/api/feedback'), env);
  assert.equal(feedback.status, 405);
  assert.equal((await worker.fetch(new Request('https://example.test/api/unknown'), env)).status, 404);
  assert.equal(assets, 1);
});
