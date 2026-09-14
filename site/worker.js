import { publicConfig } from './lib/config.mjs';
import { handleFeedback } from './lib/feedback.mjs';

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === '/api/feedback') return handleFeedback(request, env);
    if (path === '/api/config' && request.method === 'GET') return publicConfig(env);
    if (path.startsWith('/api/')) return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
    return env.ASSETS.fetch(request);
  }
};
