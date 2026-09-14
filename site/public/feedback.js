import { DRAFT_KEY, FIELDS, draftFields, issueURL, copyText } from './feedback-draft.js';

export function initFeedback({ document, location, history, storage, writeClipboard, openReview }) {
  const form = document.querySelector('#feedback-form');
  const status = document.querySelector('#form-status');
  const saved = document.querySelector('#draft-status');
  const fallback = document.querySelector('#copy-fallback');
  const text = document.querySelector('#copy-text');
  const fields = () => draftFields(Object.fromEntries(FIELDS.map(key => [key, form.elements[key].value])));
  function show(message, warning = false) {
    status.textContent = message;
    status.classList.toggle('warning', warning);
  }
  function retain() {
    const draft = fields();
    let retained = false;
    text.value = copyText(draft);
    try {
      storage().setItem(DRAFT_KEY, JSON.stringify(draft));
      retained = true;
      saved.textContent = 'Draft saved in this browser. Nothing sent.';
    } catch {
      saved.textContent = 'Browser storage is unavailable. Keep this page open or copy your draft before leaving.';
    }
    return { draft, retained };
  }
  try {
    const restored = draftFields(JSON.parse(storage().getItem(DRAFT_KEY) || '{}'));
    for (const key of FIELDS) form.elements[key].value = restored[key];
    saved.textContent = 'Your draft stays in this browser until you clear it or remove site data.';
  } catch {
    saved.textContent = 'Saved draft could not be read. Keep this page open or copy your draft before leaving.';
  }
  const version = new URLSearchParams(location.search).get('version') || '';
  if (!form.elements.version.value && /^[\w.\-]{1,40}$/.test(version)) form.elements.version.value = version;
  history.replaceState(null, '', location.pathname);
  text.value = copyText(fields());
  document.querySelector('#review').disabled = false;
  form.addEventListener('input', () => { retain(); show(''); });
  form.addEventListener('submit', event => {
    event.preventDefault();
    if (!form.reportValidity()) return;
    const { draft, retained } = retain();
    if (!retained) {
      fallback.open = true; text.focus(); text.select();
      show('Your draft could not be saved in this browser. Copy or save the complete draft below before leaving, then use Open GitHub directly and paste it into the issue form.', true);
      return;
    }
    const url = issueURL(draft);
    if (!url) {
      fallback.open = true; text.focus(); text.select();
      show('This draft is too long for a GitHub link. Copy it below, open GitHub directly, and paste it into the issue form. Your draft is retained.', true);
      return;
    }
    try {
      openReview(url);
      show('Opening GitHub in this tab. Your draft is saved; use Back to return. If GitHub does not open, copy the draft and use Open GitHub directly below.');
    } catch {
      fallback.open = true;
      show('GitHub could not be opened. Your draft is retained. Copy it and use Open GitHub directly below.', true);
    }
  });
  document.querySelector('#copy').addEventListener('click', async () => {
    const value = copyText(retain().draft);
    try { await writeClipboard(value); show('Draft copied. Review it before submitting on GitHub.'); }
    catch {
      // Use the current draft even if it changed while permission was pending.
      text.value = copyText(fields()); fallback.open = true; text.focus(); text.select();
      show('Clipboard access is unavailable. Select and copy the draft below with your keyboard or touch controls.', true);
    }
  });
  document.querySelector('#clear-draft').addEventListener('click', () => {
    try { storage().removeItem(DRAFT_KEY); }
    catch { show('Saved draft could not be cleared. Clear this site’s browser data to remove it; the visible draft is retained.', true); return; }
    form.reset(); text.value = ''; fallback.open = false;
    saved.textContent = 'Local draft cleared.'; show(''); form.elements.title.focus();
  });
}
if (typeof document !== 'undefined') initFeedback({
  document, location, history, storage: () => window.localStorage,
  writeClipboard: text => navigator.clipboard.writeText(text),
  openReview: url => location.assign(url),
});
