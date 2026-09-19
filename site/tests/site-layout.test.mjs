import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { previewResponse } from "../../scripts/preview-site.mjs";
import { sitePublicRoot } from "../../scripts/site-layout.mjs";

test("preview serves the same public root the site bundle copies", async () => {
  const release = await readFile(join(sitePublicRoot, "release.json"), "utf8");
  const response = await previewResponse(new Request("http://localhost/release.json"));
  assert.equal(response.status, 200);
  assert.equal(await response.text(), release);
  const preview = await readFile(new URL("../../scripts/preview-site.mjs", import.meta.url), "utf8");
  const build = await readFile(new URL("../../scripts/build-site.mjs", import.meta.url), "utf8");
  assert.match(preview, /site-layout\.mjs/);
  assert.match(build, /site-layout\.mjs/);
});
