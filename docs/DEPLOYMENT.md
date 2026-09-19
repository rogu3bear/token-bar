# Cloudflare Pages release contract

Purpose: let users discover, download and understand Token Bar, prepare a local
report, and explicitly review it on GitHub. Source, issues and installer downloads
are hosted on GitHub. Production URL: `https://token-bar-9v8.pages.dev`.

Use static Pages hosting with the existing advanced-mode worker. Do not provision
D1/R2, move binaries to Cloudflare, enable paid plans or GitHub Actions, or add
broad middleware. `public/_routes.json` restricts worker invocation to `/api/*`;
ordinary pages remain static.

## Application-owned artifacts

- Static source: `site/public`.
- Immutable upload directory: `build/site`, produced by `(cd site && bun install && bun run build)`. `build/site-artifact.json` binds every uploaded file by SHA-256.
- Advanced-mode entry: `site/worker.js`, bundled into `build/site/_worker.js` with pinned esbuild. Preserve `ASSETS.fetch` fallback and clear 410/no-store responses for retired `/api/feedback` and `/api/config`, for every method. These paths read no body or provider binding and make no upstream call. Unknown API paths remain 404/no-store.
- Upload the complete built directory with `cfctl`, as described under Provider-owned configuration. The former mail/config modules and Pages Functions have been retired; no raw functions directory is needed.
- Local acceptance: `(cd site && bun test)` for site changes; native checks apply only when native inputs change.
- Local visual preview: `(cd site && bun run preview)`, static only, with byte-range video responses. Drafting requires no server configuration and works in this preview.

## Provider-owned configuration

Production deployment is maintainer-operated from this repository through
`cfctl`. `cfctl call wrangler.pages-deploy` binds `build/site`, project
`token-bar`, production branch `main` and the exact source commit into a
hash-bound plan covering every uploaded file. The maintainer approves that exact
plan, it runs once, and cfctl verifies the returned deployment before the live
checks below. There is no automatic deploy on source pushes, and no dashboard,
raw Wrangler or other agent upload. Contributors need no production credentials
to build or preview the site. The capability appears in the cfctl catalog only
when `wrangler` is on `PATH` during `cfctl catalog sync`.

No Turnstile, Resend, contact address, sender or origin-validation binding is
required by this source. Existing provider resources or secrets are the operator's
custody; removing obsolete source does not authorize changing those resources.

## Report and verification boundary

The draft is stored in the browser until cleared or site data is removed. Review
on GitHub explicitly sends title, `behavior`, `version` and `macos` query fields
with `template=bug_report.yml`. Custom IDs match `.github/ISSUE_TEMPLATE/bug_report.yml`;
no labels, assignees or generic body parameter are injected. GitHub requires an
account to submit; the user reviews before publishing a public issue. The report
is transmitted in a URL at review time, not only at final submission. Review
navigates in the current tab after saving the draft; browser Back restores it.

An encoded URL over the local guard stays local and offers a copy fallback.
Clipboard denial provides selectable text; storage or navigation failure must
retain the visible draft. If local saving fails, Review stays on the page and
shows the complete copyable draft with instructions to copy before leaving.
The direct GitHub fallback uses the current tab and sends no draft fields;
existing-issue links also send no draft.
No real issue is created during synthetic acceptance.

Before claiming live, inspect deployment state, fetch all four pages, verify
headers/footer links and any enabled installer by hash. Verify local draft
retention, prefill encoding/template fields, length/copy fallbacks, and retired
API 410/no-store behavior separately. No email delivery check applies.

`release.json` is also read by the installed app's optional update check, so its keys (`version`, `available`, `url`, `sha256`, `notarized`) are a contract with `Sources/Services/UpdateCheck.swift`; `site/tests/site.test.mjs` guards them. Keep `release.json` bound to the notarized GitHub Release asset. GitHub
Packages is not a current download origin. Documentation-only changes outside
`site/` need no site rebuild or deployment when published inputs are unchanged.
