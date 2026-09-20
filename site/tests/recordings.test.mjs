import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

const motion = JSON.parse(readFileSync(new URL('../motion-preview.json', import.meta.url), 'utf8'));
const posterStart = motion.posterFrame / motion.fps;
const loopStart = motion.loopFrame / motion.fps;

function listen(events, key, fn) {
  const list = events.get(key) || [];
  list.push(fn);
  events.set(key, list);
}
function unlisten(events, key, fn) {
  const list = (events.get(key) || []).filter(listener => listener !== fn);
  if (list.length) events.set(key, list); else events.delete(key);
}
function emit(events, key) {
  for (const fn of [...(events.get(key) || [])]) fn();
}

async function setup(reduced = false) {
  const elements = new Map(), events = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, {
      textContent: '', paused: true, currentTime: 0, readyState: 1, dataset: { loopStart: String(loopStart), start: String(posterStart) },
      classList: { values: new Set(['visually-hidden']),
        add(value) { this.values.add(value); }, remove(value) { this.values.delete(value); },
        contains(value) { return this.values.has(value); } },
      pause() { this.paused = true; }, async play() { this.paused = false; },
      addEventListener: (name, fn) => listen(events, id + ':' + name, fn),
      removeEventListener: (name, fn) => unlisten(events, id + ':' + name, fn),
    });
    return elements.get(id);
  };
  const document = { hidden: false, querySelector: get,
    addEventListener: (name, fn) => listen(events, name, fn) };
  const media = { matches: reduced, addEventListener: (_, fn) => listen(events, 'motion', fn) };
  const timers = new Map();
  let observer;
  runInNewContext(await readFile(new URL('../public/demo.js', import.meta.url), 'utf8'), {
    document, matchMedia: () => media, fetch: async () => ({ ok: false }),
    window: { addEventListener: (name, fn) => listen(events, name, fn) },
    IntersectionObserver: class { constructor(fn) { observer = fn; } observe() {} },
    setTimeout: fn => { timers.set(1, fn); return 1; }, clearTimeout: id => timers.delete(id),
  });
  const flush = async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); };
  return { get, document, media, timers, flush,
    fire: async name => { emit(events, name); await flush(); },
    visible: async value => { observer([{ target: get('#dashboard-recording'), isIntersecting: value }]); await flush(); },
    repeat: async () => { const fn = timers.get(1); timers.delete(1); fn(); await flush(); },
  };
}

test('visible recordings start without a click and loop only their settled section', async () => {
  const d = await setup(), dashboard = d.get('#dashboard-recording'), menu = d.get('#menu-recording');
  assert.ok(dashboard.paused && menu.paused);
  await d.visible(true);
  assert.ok(!dashboard.paused && !menu.paused);
  assert.equal(dashboard.currentTime, posterStart);
  assert.equal(menu.currentTime, posterStart);
  dashboard.currentTime = 4; menu.currentTime = 3;
  await d.fire('#dashboard-recording:timeupdate');
  assert.equal(menu.currentTime, 4);
  await d.fire('#dashboard-recording:ended');
  assert.equal(dashboard.currentTime, loopStart);
  assert.equal(menu.currentTime, loopStart);
  assert.ok(!dashboard.paused && !menu.paused);
});

test('offscreen and hidden pages pause; explicit pause survives automatic visibility changes', async () => {
  const d = await setup(), video = d.get('#dashboard-recording');
  await d.visible(true); await d.visible(false); assert.ok(video.paused);
  await d.visible(true); assert.ok(!video.paused);
  d.document.hidden = true; await d.fire('visibilitychange'); assert.ok(video.paused);
  d.document.hidden = false; await d.fire('visibilitychange'); assert.ok(!video.paused);
  await d.fire('#demo-play:click'); assert.ok(video.paused);
  await d.visible(false); await d.visible(true); assert.ok(video.paused);
  await d.fire('#demo-play:click'); assert.ok(!video.paused);
  await d.fire('pagehide'); assert.ok(video.paused);
  await d.fire('pageshow'); assert.ok(!video.paused);
});

test('reduced motion, canceled repeats and failed autoplay leave still previews', async () => {
  const d = await setup(true), video = d.get('#dashboard-recording');
  await d.visible(true); assert.ok(video.paused);
  assert.equal(d.get('#demo-play').disabled, true);
  d.media.matches = false; await d.fire('motion'); assert.ok(!video.paused);
  await d.fire('#dashboard-recording:ended');
  d.media.matches = true; await d.fire('motion');
  assert.ok(video.paused && d.timers.size === 0);
  d.get('#menu-recording').play = async () => { throw new Error('blocked'); };
  d.media.matches = false; await d.fire('motion');
  assert.ok(video.paused && d.get('#menu-recording').paused);
  assert.match(d.get('#recording-status').textContent, /Preview paused/);
});

test('pause during a pending play cannot restart motion when its promise resolves', async () => {
  const d = await setup(), video = d.get('#dashboard-recording');
  let resolve;
  video.play = () => { video.paused = false; return new Promise(done => { resolve = done; }); };
  await d.visible(true); await d.fire('#demo-play:click');
  resolve(); await d.flush();
  assert.ok(video.paused && d.get('#menu-recording').paused);
});


test('a loop waits for both media seeks before restarting either recording', async () => {
  const d = await setup(), dashboard = d.get('#dashboard-recording'), menu = d.get('#menu-recording');
  await d.visible(true);
  dashboard.seeking = true; menu.seeking = true;
  await d.fire('#dashboard-recording:ended');
  assert.ok(dashboard.paused && menu.paused);
  dashboard.seeking = false; await d.fire('#dashboard-recording:seeked');
  assert.ok(dashboard.paused && menu.paused);
  menu.seeking = false; await d.fire('#menu-recording:seeked');
  assert.equal(dashboard.currentTime, loopStart); assert.equal(menu.currentTime, loopStart);
  assert.ok(!dashboard.paused && !menu.paused);
});

test('recordings reveal only after playback and restore image fallbacks after failure', async () => {
  const d = await setup(), dashboard = d.get('#dashboard-recording'), menu = d.get('#menu-recording');
  assert.equal(dashboard.dataset.ready, undefined);
  await d.visible(true);
  assert.equal(dashboard.dataset.ready, undefined, 'A play request is not a displayed frame');
  await d.fire('#dashboard-recording:playing');
  await d.fire('#menu-recording:playing');
  assert.equal(dashboard.dataset.ready, 'true');
  await d.fire('#dashboard-recording:error');
  assert.equal(dashboard.dataset.ready, undefined);
  assert.equal(menu.dataset.ready, undefined);
  assert.ok(dashboard.paused && menu.paused);
  await d.fire('#dashboard-recording:playing');
  assert.equal(dashboard.dataset.ready, undefined, 'A late event must not hide the fallback after failure');
});

function holdPlayback(video) {
  const attempts = [];
  video.play = () => new Promise((resolve, reject) => {
    attempts.push({ resolve() { video.paused = false; resolve(); }, reject });
  });
  return attempts;
}

test('each canceled play completion pauses immediately even while its peer remains pending', async () => {
  const d = await setup(), dashboard = d.get('#dashboard-recording'), menu = d.get('#menu-recording');
  const a = holdPlayback(dashboard), b = holdPlayback(menu);
  await d.visible(true); await d.fire('#demo-play:click');
  a[0].resolve(); await d.flush();
  assert.ok(dashboard.paused, 'A canceled late completion must not wait for the other video');
  b[0].resolve(); await d.flush();
  assert.ok(dashboard.paused && menu.paused);
});

test('retry starts immediately and an obsolete rejection cannot stop the new playback', async () => {
  const d = await setup(), dashboard = d.get('#dashboard-recording'), menu = d.get('#menu-recording');
  const a = holdPlayback(dashboard), b = holdPlayback(menu);
  await d.visible(true); await d.fire('#demo-play:click'); await d.fire('#demo-play:click');
  assert.equal(a.length, 2); assert.equal(b.length, 2);
  a[1].resolve(); b[1].resolve(); await d.flush();
  a[0].reject(new Error('canceled')); b[0].resolve(); await d.flush();
  assert.ok(!dashboard.paused && !menu.paused);
  assert.equal(d.get('#demo-play').ariaLabel, 'Pause preview');
});

test('a failed startup pauses a peer that resolves later and permits an immediate retry', async () => {
  const d = await setup(), dashboard = d.get('#dashboard-recording'), menu = d.get('#menu-recording');
  const a = holdPlayback(dashboard), b = holdPlayback(menu);
  await d.visible(true);
  b[0].reject(new Error('blocked')); await d.flush();
  a[0].resolve(); await d.flush();
  assert.ok(dashboard.paused && menu.paused);
  await d.fire('#demo-play:click');
  assert.equal(a.length, 2);
  a[1].resolve(); b[1].resolve(); await d.flush();
  assert.ok(!dashboard.paused && !menu.paused);
});

test('recording failures keep a visible warning through visibility and reduced-motion updates', async () => {
  const d = await setup();
  await d.visible(true);
  await d.fire('#dashboard-recording:error');
  const status = d.get('#recording-status');
  assert.match(status.textContent, /^Warning: Recording unavailable/);
  assert.equal(status.classList.contains('visually-hidden'), false);
  assert.equal(status.classList.contains('warning'), true);
  await d.visible(false); await d.visible(true);
  d.media.matches = true; await d.fire('motion');
  assert.match(status.textContent, /^Warning: Recording unavailable/);
  assert.equal(d.get('#demo-play').disabled, true);
});

test('published recordings use the motion-preview clock', async () => {
  const html = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(html, new RegExp(`data-start="${posterStart}"`));
  assert.match(html, new RegExp(`data-loop-start="${loopStart}"`));
  const encode = await readFile(new URL('../../scripts/encode-motion-preview.sh', import.meta.url), 'utf8');
  assert.match(encode, /site\/motion-preview\.json/);
});
