export const DRAFT_KEY = 'tokenbar.issue-draft.v1';
export const MAX_ISSUE_URL = 7500;
export const VERSION_QUERY_MAX = 40;
export const FIELDS = ['title', 'behavior', 'version', 'macos'];
export function draftFields(value = {}) {
  return Object.fromEntries(FIELDS.map(key => [key, typeof value?.[key] === 'string' ? value[key] : '']));
}
export function issueURL(value) {
  const draft = draftFields(value);
  const url = new URL('https://github.com/rogu3bear/token-bar/issues/new');
  url.searchParams.set('template', 'bug_report.yml');
  for (const key of FIELDS) if (draft[key]) url.searchParams.set(key, draft[key]);
  return url.href.length <= MAX_ISSUE_URL ? url.href : null;
}
export function copyText(value) {
  const draft = draftFields(value);
  return `${draft.title}\n\n${draft.behavior}\n\nApp version: ${draft.version || 'Not supplied'}\nmacOS version: ${draft.macos || 'Not supplied'}`;
}
