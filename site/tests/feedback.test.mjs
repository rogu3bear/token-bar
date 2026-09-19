import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DRAFT_KEY, FIELDS, VERSION_QUERY_MAX, issueURL, copyText } from '../public/feedback-draft.js';
import { initFeedback } from '../public/feedback.js';
const report = { title: 'Spacing & units #1', behavior: 'A <script> & Unicode 界 test.\nExpected a stable dial.', version: '0.1.2', macos: '15.6' };
function setup({ initial, search = '', storageFails = false, clipboardFails = false, navigationFails = false } = {}) {
  const events = new Map(), nodes = new Map(), data = new Map(), opened = [], copied = [], addresses = [];
  if (initial) data.set(DRAFT_KEY, JSON.stringify(initial));
  function node(id) {
    if (!nodes.has(id)) nodes.set(id, { value: '', textContent: '', disabled: false, open: false,
      classList: { toggle() {} }, focus() { this.focused = true; }, select() { this.selected = true; },
      addEventListener: (name, fn) => events.set(id + ':' + name, fn) });
    return nodes.get(id);
  }
  const form = node('#feedback-form'); form.elements = Object.fromEntries(FIELDS.map(key => [key, node(key)]));
  form.reportValidity = () => form.elements.title.value.length >= 3 && form.elements.behavior.value.length >= 10;
  form.reset = () => { for (const key of FIELDS) form.elements[key].value = ''; };
  initFeedback({ document: { querySelector: node }, location: { search, pathname: '/feedback/' },
    history: { replaceState: (_a, _b, path) => addresses.push(path) },
    storage: () => {
      if (storageFails) throw new Error('storage unavailable');
      return { getItem: key => data.get(key), setItem: (key, value) => data.set(key, value), removeItem: key => data.delete(key) };
    },
    writeClipboard: async text => { if (clipboardFails) throw new Error('denied'); copied.push(text); },
    openReview: url => { if (navigationFails) throw new Error('blocked'); opened.push(url); },
  });
  return { node, form, data, opened, copied, addresses,
    fill(value) { for (const key of FIELDS) form.elements[key].value = value[key] || ''; events.get('#feedback-form:input')(); },
    fire: async name => events.get(name)({ preventDefault() {} }),
  };
}
test('prefill uses actual YAML IDs, safe encoding and no extra fields or unsupported labels', async () => {
  const template = await readFile(new URL('../../.github/ISSUE_TEMPLATE/bug_report.yml', import.meta.url), 'utf8');
  const ids = [...template.matchAll(/id: (\w+)/g)].map(match => match[1]);
  const url = new URL(issueURL({ ...report, email: 'private@example.test', body: 'wrong', labels: 'not-supported' }));
  assert.equal(url.origin, 'https://github.com'); assert.equal(url.pathname, '/rogu3bear/token-bar/issues/new');
  assert.equal(url.searchParams.get('template'), 'bug_report.yml');
  for (const field of FIELDS) {
    assert.equal(url.searchParams.get(field), report[field]);
    if (field !== 'title') assert.ok(ids.includes(field));
  }
  assert.deepEqual([...url.searchParams.keys()].sort(), ['template', ...FIELDS].sort());
  assert.ok(!url.href.includes('<script>')); assert.ok(!url.href.includes('private'));
});
test('draft edits stay local; explicit review retains the draft and transmits only then', async () => {
  const app = setup(); app.fill(report);
  assert.deepEqual(app.opened, []); assert.deepEqual(JSON.parse(app.data.get(DRAFT_KEY)), report);
  await app.fire('#feedback-form:submit');
  assert.equal(app.opened.length, 1); assert.equal(new URL(app.opened[0]).searchParams.get('behavior'), report.behavior);
  assert.equal(app.form.elements.behavior.value, report.behavior);
  assert.equal(app.node('#copy-text').value, copyText(report));
});
test('draft restores, version convenience is removed from address and never replaces a saved version', () => {
  const app = setup({ initial: report, search: '?version=9.9.9&email=private' });
  assert.equal(app.form.elements.version.value, '0.1.2'); assert.equal(app.form.elements.behavior.value, report.behavior);
  assert.deepEqual(app.addresses, ['/feedback/']);
  assert.equal(setup({ search: '?version=0.1.2' }).form.elements.version.value, '0.1.2');
});
test('version convenience uses the same length the app truncates to', async () => {
  const swift = await readFile(new URL('../../Sources/Services/Feedback.swift', import.meta.url), 'utf8');
  assert.match(swift, new RegExp(`versionLimit = ${VERSION_QUERY_MAX}`));
  const allowed = 'v'.repeat(VERSION_QUERY_MAX);
  assert.equal(setup({ search: `?version=${allowed}` }).form.elements.version.value, allowed);
  assert.equal(setup({ search: `?version=${allowed}x` }).form.elements.version.value, '');
});
test('encoded length guard prevents navigation and retains a selectable complete draft', async () => {
  const app = setup(); const long = { ...report, behavior: '界'.repeat(2400) }; app.fill(long);
  await app.fire('#feedback-form:submit');
  assert.equal(issueURL(long), null); assert.equal(app.opened.length, 0);
  assert.equal(app.node('#copy-fallback').open, true); assert.equal(app.node('#copy-text').selected, true);
  assert.ok(app.node('#copy-text').value.includes(long.behavior)); assert.deepEqual(JSON.parse(app.data.get(DRAFT_KEY)), long);
});
test('copy succeeds without navigation and clipboard denial preserves selectable text', async () => {
  const good = setup(); good.fill(report); await good.fire('#copy:click');
  assert.deepEqual(good.copied, [copyText(report)]); assert.equal(good.opened.length, 0);
  const bad = setup({ clipboardFails: true }); bad.fill(report); await bad.fire('#copy:click');
  assert.equal(bad.node('#copy-fallback').open, true); assert.equal(bad.node('#copy-text').value, copyText(report));
  assert.equal(bad.node('#copy-text').selected, true); assert.match(bad.node('#form-status').textContent, /Clipboard access/);
});
test('storage failure prevents review navigation and exposes the complete copyable draft', async () => {
  const app = setup({ storageFails: true }); app.fill(report);
  assert.match(app.node('#draft-status').textContent, /storage is unavailable/);
  await app.fire('#feedback-form:submit'); assert.match(app.node('#form-status').textContent, /Open GitHub directly/);
  assert.equal(app.opened.length, 0); assert.equal(app.node('#copy-fallback').open, true);
  assert.equal(app.node('#copy-text').value, copyText(report)); assert.equal(app.node('#copy-text').selected, true);
  assert.match(app.node('#form-status').textContent, /before leaving/);
  assert.equal(app.form.elements.behavior.value, report.behavior);
  await app.fire('#clear-draft:click'); assert.equal(app.form.elements.behavior.value, report.behavior);
});
test('thrown review navigation preserves the saved and visible draft with a direct fallback', async () => {
  const app = setup({ navigationFails: true }); app.fill(report);
  await app.fire('#feedback-form:submit');
  assert.deepEqual(JSON.parse(app.data.get(DRAFT_KEY)), report);
  assert.equal(app.form.elements.behavior.value, report.behavior);
  assert.equal(app.node('#copy-fallback').open, true);
  assert.match(app.node('#form-status').textContent, /could not be opened/);
});
test('clear removes only this local draft; invalid submission never opens GitHub', async () => {
  const app = setup({ initial: report }); app.data.set('unrelated', 'keep');
  await app.fire('#clear-draft:click'); assert.equal(app.data.has(DRAFT_KEY), false); assert.equal(app.data.get('unrelated'), 'keep');
  assert.equal(app.form.elements.title.value, ''); await app.fire('#feedback-form:submit'); assert.equal(app.opened.length, 0);
});
test('page always offers existing issue search, direct no-draft fallback and public/account disclosure', async () => {
  const html = await readFile(new URL('../public/feedback/index.html', import.meta.url), 'utf8');
  assert.match(html, /issues\/new\/choose/); assert.match(html, /Search existing issues/);
  assert.match(html, /public and require a GitHub account/); assert.match(html, /before you submit/);
  assert.match(html, /<noscript>/); assert.doesNotMatch(html, /name="email"|turnstile|api\/feedback/i);
  assert.doesNotMatch(html, /target="_blank"/); assert.match(html, /Copy your draft before leaving/);
});
