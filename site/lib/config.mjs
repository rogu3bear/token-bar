export function publicConfig(env) {
  return new Response(JSON.stringify({
    siteKey: env.TURNSTILE_SITE_KEY || null,
    available: Boolean(env.TURNSTILE_SITE_KEY && env.TURNSTILE_SECRET_KEY && env.RESEND_API_KEY && env.FEEDBACK_TO && env.FEEDBACK_FROM && env.SITE_ORIGIN)
  }), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
}
