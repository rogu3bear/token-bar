import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import worker, { RETIRED_API_PATHS } from "../worker.js";

test("retired API paths are named once and never send", async () => {
  assert.deepEqual(RETIRED_API_PATHS, ["/api/config", "/api/feedback"]);
  const routes = JSON.parse(
    await readFile(new URL("../public/_routes.json", import.meta.url), "utf8"),
  );
  assert.deepEqual(routes.include, ["/api/*"]);
  const env = { ASSETS: { fetch: async () => new Response("static") } };
  for (const path of RETIRED_API_PATHS) {
    assert.ok(path.startsWith("/api/"));
    const response = await worker.fetch(
      new Request("https://example.test" + path, { method: "POST" }),
      env,
    );
    assert.equal(response.status, 410);
    const body = await response.json();
    assert.match(body.error, /retired/);
    assert.match(body.error, /\/feedback\//);
  }
});
