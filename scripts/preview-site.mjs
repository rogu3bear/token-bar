import { resolve, sep } from 'node:path';
import { sitePublicRoot } from './site-layout.mjs';

// Static-only preview. Byte ranges let native video recordings seek and loop.
export async function previewResponse(request, root = sitePublicRoot) {
  if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405 });
  let pathname;
  try { pathname = decodeURIComponent(new URL(request.url).pathname); }
  catch { return new Response(null, { status: 400 }); }
  const path = resolve(root, '.' + pathname + (pathname.endsWith('/') ? 'index.html' : ''));
  if (!path.startsWith(resolve(root) + sep)) return new Response(null, { status: 403 });
  const file = Bun.file(path);
  if (!await file.exists()) return new Response(null, { status: 404 });
  const size = file.size;
  const headers = { 'Accept-Ranges': 'bytes', 'Content-Type': file.type, 'Cache-Control': 'no-store' };
  let start = 0, end = size - 1, status = 200;
  const range = request.headers.get('Range');
  if (range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!match || (!match[1] && !match[2])) return new Response(null, { status: 416, headers: { ...headers, 'Content-Range': `bytes */${size}` } });
    start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
    end = match[1] && match[2] ? Math.min(size - 1, Number(match[2])) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) {
      return new Response(null, { status: 416, headers: { ...headers, 'Content-Range': `bytes */${size}` } });
    }
    headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
    status = 206;
  }
  headers['Content-Length'] = String(Math.max(0, end - start + 1));
  return new Response(request.method === 'HEAD' ? null : file.slice(start, end + 1), { status, headers });
}

if (import.meta.main) {
  const server = Bun.serve({ hostname: '127.0.0.1', port: Number(process.env.PORT || 4173), fetch: request => previewResponse(request) });
  console.log(`Static preview: ${server.url}`);
}
