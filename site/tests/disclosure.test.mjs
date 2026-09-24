import { test } from 'node:test';
import assert from 'node:assert/strict';
import { enhanceDisclosure, setDisclosureOpen } from '../public/disclosure.js';

function fixture() {
  const events = {}, animations = [], attributes = {};
  const content = { inert: true };
  const summary = {
    addEventListener: (name, fn) => { events[name] = fn; },
    setAttribute: (name, value) => { attributes[name] = value; },
    getBoundingClientRect: () => ({ height: 44 }),
  };
  let visibleHeight;
  const element = {
    open: false, dataset: {}, classList: { add() {}, remove() {} },
    querySelector: selector => selector === 'summary' ? summary : content,
    getBoundingClientRect: () => ({ height: visibleHeight ?? (element.open ? 300 : 44) }),
    animate: (frames, options) => {
      const animation = { frames, options, canceled: false, cancel() { this.canceled = true; visibleHeight = undefined; } };
      animations.push(animation);
      return animation;
    },
  };
  const media = { matches: false, addEventListener: (_, fn) => { events.motion = fn; } };
  enhanceDisclosure(element, { media, resizeTarget: { addEventListener: (_, fn) => { events.resize = fn; } },
    style: { getPropertyValue: key => key === '--motion-disclosure' ? '240ms' : 'cubic-bezier(.2,.8,.2,1)' } });
  return { element, content, media, animations, attributes, events,
    click: () => events.click({ preventDefault() {} }), height: value => { visibleHeight = value; } };
}

test('rapid reversal starts at the visible height; obsolete completions cannot close the latest request', () => {
  const f = fixture();
  f.click(); const opening = f.animations[0];
  f.height(130); f.click(); const closing = f.animations[1];
  assert.equal(opening.canceled, true);
  assert.equal(closing.frames[0].height, '130px');
  assert.equal(f.content.inert, true);
  f.height(90); f.click(); const latest = f.animations[2];
  assert.equal(latest.frames[0].height, '90px');
  closing.onfinish(); opening.onfinish(); latest.onfinish();
  assert.equal(f.element.open, true);
  assert.equal(f.attributes['aria-expanded'], 'true');
  assert.equal(f.content.inert, false);
});

test('a programmatic clipboard fallback immediately opens and cancels an in-flight close', () => {
  const f = fixture();
  setDisclosureOpen(f.element, true); f.click();
  const closing = f.animations[0];
  setDisclosureOpen(f.element, true);
  closing.onfinish();
  assert.equal(closing.canceled, true);
  assert.equal(f.element.open, true);
  assert.equal(f.content.inert, false);
  setDisclosureOpen(f.element, false);
  assert.equal(f.element.open, false);
});

test('reduced motion and resize settle the latest intent without leaving clipped content', () => {
  const f = fixture();
  f.click(); f.events.resize();
  assert.equal(f.element.open, true);
  f.click(); f.media.matches = true; f.events.motion();
  assert.equal(f.element.open, false);
  const count = f.animations.length;
  f.click();
  assert.equal(f.element.open, true);
  assert.equal(f.animations.length, count);
});

test('without the animation API the native disclosure remains functional', () => {
  const f = fixture(); f.element.animate = undefined;
  f.click(); assert.equal(f.element.open, true);
  f.click(); assert.equal(f.element.open, false);
});
