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
test("every local asset a page references exists in the public tree", async () => {
  const { access } = await import("node:fs/promises");
  for (const path of ["index.html", "feedback/index.html", "privacy/index.html", "terms/index.html"]) {
    const html = await read(path);
    for (const [, target] of html.matchAll(/(?:src|href|poster)="(\/[^"#?]+)/g)) {
      if (target.endsWith("/")) continue;
      await access(new URL(`../public${target}`, import.meta.url));
    }
  }
});
test("function invocations are restricted to API paths", async () => {
  assert.deepEqual(JSON.parse(await read("_routes.json")).include, ["/api/*"]);
});

test('advanced-mode retires both APIs without reading bindings, bodies or contacting providers', async () => {
  const { default: worker } = await import('../worker.js');
  let assets = 0;
  const env = new Proxy({ ASSETS: { fetch: async () => { assets++; return new Response('static'); } } }, {
    get(target, key) { if (key !== 'ASSETS') throw new Error('Obsolete binding read'); return target[key]; }
  });
  for (const path of ['/api/config', '/api/feedback']) for (const method of ['GET', 'POST', 'OPTIONS', 'DELETE']) {
    const request = new Request('https://example.test' + path, { method });
    request.json = () => { throw new Error('Body must not be read'); };
    const response = await worker.fetch(request, env);
    assert.equal(response.status, 410); assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assert.match((await response.json()).error, /retired/);
  }
  assert.equal(assets, 0);
  assert.equal((await worker.fetch(new Request('https://example.test/api/unknown'), env)).status, 404);
  assert.equal(await (await worker.fetch(new Request('https://example.test/'), env)).text(), 'static');
  assert.equal(assets, 1);
});
test('all four pages share the complete accessible footer and obsolete CAPTCHA allowances are absent', async () => {
  let expected;
  for (const path of ['index.html', 'feedback/index.html', 'privacy/index.html', 'terms/index.html']) {
    const html = await read(path); const footer = html.match(/<footer[\s\S]*?<\/footer>/)[0];
    expected ??= footer; assert.equal(footer, expected);
    for (const label of ['Source', 'Releases', 'Report an issue', 'Privacy', 'MIT License', 'Terms', 'JKCA', '© 2026 Token Bar contributors']) assert.ok(footer.includes(label));
    assert.match(footer, /aria-label="Footer"/); assert.match(footer, /href="https:\/\/jkca.me"/);
  }
  assert.doesNotMatch(await read('_headers'), /challenges.cloudflare.com/);
});
test('dashboard recording names the poster start so first play cannot flash t=0', async () => {
  assert.match(await read('index.html'), /id="dashboard-recording"[^>]*data-start="3.5"/);
});
