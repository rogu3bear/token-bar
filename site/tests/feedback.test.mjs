import test from "node:test";
import assert from "node:assert/strict";
import { handleFeedback, issueURL } from "../lib/feedback.mjs";
import { onRequestGet } from "../functions/api/config.js";
const env = {
  SITE_ORIGIN: "https://token-bar-9v8.pages.dev",
  RESEND_API_KEY: "fixture-secret",
  TURNSTILE_SECRET_KEY: "fixture-turnstile",
  TURNSTILE_SITE_KEY: "public-key",
  FEEDBACK_TO: "maintainer@example.test",
  FEEDBACK_FROM: "App <app@example.test>",
};
const fields = {
  title: "The dial stopped",
  description: "After changing units the needle did not move.",
  version: "2.0.0",
  email: "reporter@example.test",
  consent: true,
  token: "fixture-token",
};
const request = (data = fields, headers = {}) =>
  new Request(`${env.SITE_ORIGIN}/api/feedback`, {
    method: "POST",
    headers: {
      Origin: env.SITE_ORIGIN,
      "Content-Type": "application/json",
      ...headers,
    },
    body: JSON.stringify(data),
  });
function provider(options = {}) {
  const calls = [];
  return {
    calls,
    fetcher: async (url, init) => {
      calls.push({ url, init });
      if (url.includes("siteverify"))
        return Response.json({
          success: true,
          hostname: "token-bar-9v8.pages.dev",
          action: "feedback",
          ...options.challenge,
        });
      return Response.json(options.result ?? { id: "fixture-email-id" }, {
        status: options.mailStatus ?? 200,
      });
    },
  };
}
test("private contact is delivered only to the fixed recipient, never the issue URL", async () => {
  const mock = provider();
  const response = await handleFeedback(
    request({ ...fields, to: "attacker@example.test" }),
    env,
    mock.fetcher,
  );
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.status, "email_accepted");
  const draft = new URL(result.issueURL);
  assert.equal(draft.origin, "https://github.com");
  assert.equal(draft.pathname, "/rogu3bear/token-bar/issues/new");
  assert.match(draft.searchParams.get("body"), /After changing units/);
  assert.ok(!decodeURIComponent(result.issueURL).includes(fields.email));
  assert.ok(!JSON.stringify(result).includes(env.RESEND_API_KEY));
  const email = JSON.parse(mock.calls[1].init.body);
  assert.deepEqual(email.to, [env.FEEDBACK_TO]);
  assert.equal(email.reply_to, fields.email);
  assert.ok(email.text.includes(fields.email));
  assert.ok(email.text.includes(result.reference));
});
test("cross-origin, missing consent, invalid email and oversized input cannot send", async () => {
  const mock = provider();
  for (const bad of [
    request(fields, { Origin: "https://evil.example" }),
    request({ ...fields, consent: false }),
    request({ ...fields, email: "a@b.test\nBcc: x@y.test" }),
    request({ ...fields, description: "x".repeat(13000) }),
  ]) {
    assert.ok((await handleFeedback(bad, env, mock.fetcher)).status >= 400);
  }
  assert.equal(mock.calls.length, 0);
});
test("email accidentally entered into public report fields is rejected", async () => {
  const mock = provider();
  const response = await handleFeedback(
    request({
      ...fields,
      description: "Please reply to REPORTER@example.test",
    }),
    env,
    mock.fetcher,
  );
  assert.equal(response.status, 400);
  assert.equal(mock.calls.length, 0);
});
test("failed, wrong-host and wrong-action Turnstile cannot reach Resend", async () => {
  for (const challenge of [
    { success: false },
    { hostname: "evil.example" },
    { action: "login" },
  ]) {
    const mock = provider({ challenge });
    assert.equal(
      (await handleFeedback(request(), env, mock.fetcher)).status,
      400,
    );
    assert.equal(mock.calls.length, 1);
  }
});
test("email provider failure is not reported as acceptance", async () => {
  for (const options of [{ mailStatus: 429 }, { result: {} }]) {
    const mock = provider(options);
    const response = await handleFeedback(request(), env, mock.fetcher);
    assert.equal(response.status, 502);
    assert.ok(!(await response.text()).includes("issueURL"));
  }
});
test("missing server configuration fails closed without provider calls", async () => {
  const mock = provider();
  assert.equal(
    (
      await handleFeedback(
        request(),
        { ...env, RESEND_API_KEY: "" },
        mock.fetcher,
      )
    ).status,
    503,
  );
  assert.equal(mock.calls.length, 0);
  const config = await onRequestGet({ env }).json();
  assert.deepEqual(config, { siteKey: "public-key", available: true });
});
test("issue generation encodes text and allowlists public fields", () => {
  const result = new URL(
    issueURL(
      { ...fields, title: "Spacing & units #1", email: "secret@example.test" },
      "ref",
    ),
  );
  assert.equal(result.searchParams.get("title"), "Spacing & units #1");
  assert.ok(!result.toString().includes("secret"));
});
test("network uncertainty does not leak provider error details", async () => {
  const response = await handleFeedback(request(), env, async () => {
    throw new Error("fixture-secret");
  });
  assert.equal(response.status, 502);
  assert.ok(!(await response.text()).includes("fixture-secret"));
});
