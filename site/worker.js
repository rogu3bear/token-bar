export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === '/api/feedback' || path === '/api/config') {
      return Response.json({ error: 'Email feedback has been retired. Prepare a local draft at /feedback/ and review it on GitHub.' },
        { status: 410, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
    }
    if (path.startsWith('/api/')) return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
    return env.ASSETS.fetch(request);
  }
};
