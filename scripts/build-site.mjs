import { createRequire } from 'node:module';
import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { sitePublicURL, siteWorkerURL } from './site-layout.mjs';
import { generateChangelog } from './generate-changelog.mjs';
const { build } = createRequire(new URL('../site/package.json', import.meta.url))('esbuild');
const root = new URL('../', import.meta.url);
const output = new URL('build/site/', root);
await rm(output, { recursive: true, force: true }); // Owned, disposable build output only.
await mkdir(output, { recursive: true });
await generateChangelog();
await cp(sitePublicURL, output, { recursive: true });
await build({ entryPoints: [fileURLToPath(siteWorkerURL)], bundle: true, format: 'esm', platform: 'browser', target: 'es2022', outfile: fileURLToPath(new URL('_worker.js', output)), legalComments: 'none' });
const files = [];
async function inventory(directory, prefix = '') {
  for (const item of (await readdir(directory, { withFileTypes: true })).sort((a,b) => a.name.localeCompare(b.name))) {
    const path = prefix + item.name;
    const url = new URL(item.name + (item.isDirectory() ? '/' : ''), directory);
    if (item.isDirectory()) await inventory(url, path + '/');
    else { const bytes = await readFile(url); files.push({ path, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }); }
  }
}
await inventory(output);
const manifest = { files, manifestSHA256: createHash('sha256').update(JSON.stringify(files)).digest('hex') };
await writeFile(new URL('build/site-artifact.json', root), JSON.stringify(manifest, null, 2) + '\n');
console.log(`Built ${files.length} files including advanced-mode _worker.js; artifact manifest ${manifest.manifestSHA256}`);
