# Cloudflare Pages release contract

Purpose: let users discover, download, and understand Token Bar, and submit feedback with a private contact address. The public source and installer downloads are hosted on GitHub. The production site URL is `https://token-bar-9v8.pages.dev`.

Use static Pages hosting and one small feedback API. Do not provision D1/R2, move binaries to Cloudflare, enable paid plans, enable GitHub Actions, or add broad middleware. `public/_routes.json` restricts Functions to `/api/*`; ordinary page requests remain static.

## Application-owned artifacts

- Static source: `site/public`
- Immutable upload directory: `build/site`, produced by `(cd site && bun install && bun run build)`. `build/site-artifact.json` binds every uploaded file by SHA-256.
- Pages Functions directory: `site/functions`
- Shared function modules: `site/lib/feedback.mjs` and `site/lib/config.mjs`
- Advanced-mode entry: `site/worker.js`, bundled into `build/site/_worker.js` with the pinned esbuild dependency. It preserves API handlers and static `ASSETS.fetch` fallback. Upload this complete built directory through the maintainer's configured Pages release tooling; do not upload raw `functions/` or remove the feedback API.
- Local acceptance: `./scripts/test.sh` and `(cd site && bun test)`
- Local visual preview: `(cd site && bun run preview)`; this serves static content only, with byte-range responses for native video seeking. Private feedback fails closed without its server configuration.

## Provider-owned configuration

Production deployment is maintainer-operated. Contributors can build and preview
the complete website locally without production credentials.

The maintainer verifies the target account and project, records the exact source
commit and artifact hashes, and publishes the complete built directory. No automatic deploy on source pushes.

Required production bindings:

| Name | Purpose |
| --- | --- |
| `SITE_ORIGIN` | Exact production HTTPS origin for request and challenge validation |
| `TURNSTILE_SITE_KEY` | Public site key restricted to the site's hostname |
| `TURNSTILE_SECRET_KEY` | Server-only Turnstile secret |
| `RESEND_API_KEY` | Server-only Resend key, preferably send-only and scoped to the verified sender domain |
| `FEEDBACK_TO` | Fixed maintainer recipient; never supplied by the browser |
| `FEEDBACK_FROM` | Verified Resend sender address |

Use Turnstile action `feedback`. Test keys are for isolated local tests only, never production. Do not echo secret values into receipts, scripts, history, source, or tool output. Bind existing secrets through the authorized local secret source, without copying them into Git.

Private feedback requires exact Origin validation, bounded fields/body, server-side Turnstile hostname/action checks, a fixed recipient, provider acceptance before offering the issue draft, and no request-body logging. The issue URL includes only title, report, version, and random reference ID. A public issue is not created automatically. A successful Resend response proves acceptance, not inbox delivery; a controlled mail test and private receipt are needed for delivery verification.

## Cost and verification

Static hosting, Functions and email have separate usage and pricing rules. Confirm the user's current account plan and costs before provisioning. Keep the site static even if feedback is unavailable; never broaden the API routes just to simplify deployment.

Before claiming live: read provider deployment state, fetch the pages.dev landing/feedback/privacy/terms pages, check security headers, verify the GitHub source link, verify any enabled download by hash, and record feedback verification separately. A real mail submission requires
explicit authorization; without it, check non-sending API behavior and state
that inbox delivery was not tested. The private contact address must not appear in public issue URLs, repository files, page source, or response logs.

GitHub Packages is an additional installer archive, with its own visibility;
it is not the website's download origin. Keep `release.json` bound to the
notarized Release asset. Documentation-only changes outside `site/` require no
site rebuild or Cloudflare deployment when the published inputs are unchanged.
