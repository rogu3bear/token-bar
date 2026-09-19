import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { previewResponse } from '../../scripts/preview-site.mjs';

test('static preview serves exact video ranges and HEAD metadata for seeking', async () => {
  const source = new Uint8Array(await Bun.file(new URL('../public/menu-bar-demo.mp4', import.meta.url)).arrayBuffer());
  const response = await previewResponse(new Request('http://localhost/menu-bar-demo.mp4', { headers: { Range: 'bytes=10-99' } }));
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('Content-Range'), `bytes 10-99/${source.length}`);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), source.slice(10, 100));
  const head = await previewResponse(new Request('http://localhost/menu-bar-demo.mp4', { method: 'HEAD' }));
  assert.equal(head.headers.get('Accept-Ranges'), 'bytes');
  assert.equal(head.headers.get('Content-Length'), String(source.length));
  assert.equal((await head.arrayBuffer()).byteLength, 0);
  const invalid = await previewResponse(new Request('http://localhost/menu-bar-demo.mp4', { headers: { Range: `bytes=${source.length}-` } }));
  assert.equal(invalid.status, 416);
});

test('download rewrite uses the published GitHub Release prefix', async () => {
  const demo = await readFile(new URL('../public/demo.js', import.meta.url), 'utf8');
  const match = demo.match(/GITHUB_DOWNLOAD_PREFIX = "([^"]+)"/);
  assert.ok(match, 'demo.js must name the GitHub Release prefix');
  const prefix = match[1];
  const release = JSON.parse(await readFile(new URL('../public/release.json', import.meta.url), 'utf8'));
  assert.ok(release.url.startsWith(prefix), 'release.json must stay on a GitHub Release asset');
  const html = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.ok(html.includes(prefix), 'the static download link must use the same prefix');
});
