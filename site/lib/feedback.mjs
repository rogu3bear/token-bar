const MAX_BODY = 12000;
const REPOSITORY = "https://github.com/rogu3bear/token-bar";
const EMAIL = /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/;
const PUBLIC_FIELDS = ["title", "description", "version"];
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });

export function issueURL(report, reference) {
  // This allowlist deliberately never accepts the private contact field.
  const url = new URL(`${REPOSITORY}/issues/new`);
  url.searchParams.set("title", report.title);
  url.searchParams.set(
    "body",
    `${report.description}\n\n### App version\n${report.version || "Not supplied"}\n\n### Feedback reference\n${reference}\n\nContact details were sent privately to the maintainer.`,
  );
  return url.toString();
}

async function limitedJSON(request) {
  if (!request.body) throw new Error("empty");
  const reader = request.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > MAX_BODY) {
        await reader.cancel();
        throw new Error("large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let position = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, position);
    position += chunk.length;
  }
  return JSON.parse(new TextDecoder().decode(bytes));
}

export async function handleFeedback(request, env, fetcher = fetch) {
  if (request.method !== "POST") return json({ error: "Use POST." }, 405);
  const site = env.SITE_ORIGIN;
  if (
    !site ||
    request.headers.get("Origin") !== site ||
    new URL(request.url).origin !== site
  ) {
    return json({ error: "Open the feedback form on the official site." }, 403);
  }
  if (
    !env.RESEND_API_KEY ||
    !env.FEEDBACK_TO ||
    !env.FEEDBACK_FROM ||
    !env.TURNSTILE_SECRET_KEY
  ) {
    return json(
      {
        error:
          "Private feedback is not configured yet. Please try again later.",
      },
      503,
    );
  }
  if (!request.headers.get("Content-Type")?.startsWith("application/json"))
    return json({ error: "Expected JSON." }, 415);
  let data;
  try {
    data = await limitedJSON(request);
  } catch {
    return json({ error: "Invalid or oversized form." }, 400);
  }
  if (!data || typeof data !== "object" || Array.isArray(data))
    return json({ error: "Invalid form." }, 400);
  const lengths = {
    title: [3, 100],
    description: [10, 2500],
    version: [0, 40],
    email: [3, 254],
    token: [1, 2048],
  };
  for (const [key, [min, max]] of Object.entries(lengths)) {
    if (
      typeof data[key] !== "string" ||
      data[key].trim().length < min ||
      data[key].length > max
    ) {
      return json(
        { error: `Check the ${key === "token" ? "verification" : key} field.` },
        400,
      );
    }
  }
  const email = data.email.trim();
  if (
    !EMAIL.test(email) ||
    /[\r\n\x00-\x1f\x7f]/.test(email) ||
    data.consent !== true
  )
    return json(
      { error: "Enter a valid private email and confirm consent." },
      400,
    );
  // Prevent accidental copying of the contact email into the public draft.
  if (
    PUBLIC_FIELDS.some((key) =>
      data[key].toLowerCase().includes(email.toLowerCase()),
    )
  ) {
    return json(
      {
        error:
          "Remove your contact email from the public report fields. Use only the private email field.",
      },
      400,
    );
  }
  try {
    const verification = await fetcher(
      "https://challenges.cloudflare.com/turnstile/v0/siteverify",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          secret: env.TURNSTILE_SECRET_KEY,
          response: data.token,
        }),
        signal: AbortSignal.timeout(10000),
      },
    );
    const challenge = verification.ok ? await verification.json() : null;
    if (
      !challenge?.success ||
      challenge.hostname !== new URL(site).hostname ||
      challenge.action !== "feedback"
    ) {
      return json(
        { error: "Verification expired or failed. Please verify again." },
        400,
      );
    }
    const report = Object.fromEntries(
      PUBLIC_FIELDS.map((key) => [key, data[key].trim()]),
    );
    const reference = crypto.randomUUID();
    const draft = issueURL(report, reference);
    if (draft.length > 8000)
      return json(
        { error: "Shorten the report so it fits in a GitHub issue draft." },
        400,
      );
    const message = await fetcher("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
        "Idempotency-Key": `feedback/${reference}`,
      },
      body: JSON.stringify({
        from: env.FEEDBACK_FROM,
        to: [env.FEEDBACK_TO],
        reply_to: email,
        subject: `[Token Bar] ${report.title.replace(/[\r\n]/g, " ")}`,
        text: `Private contact: ${email}\nReference: ${reference}\nApp version: ${report.version || "Not supplied"}\n\n${report.description}\n\nThe reporter may separately submit a public GitHub issue containing this reference. No public issue is created by this email.`,
      }),
      signal: AbortSignal.timeout(10000),
    });
    if (!message.ok)
      return json(
        {
          error:
            "The email provider did not accept your report. Nothing was posted to GitHub. Please try again later.",
        },
        502,
      );
    const accepted = await message.json();
    if (typeof accepted.id !== "string" || !accepted.id)
      return json(
        {
          error:
            "Email acceptance could not be confirmed. Nothing was posted to GitHub.",
        },
        502,
      );
    return json({ reference, issueURL: draft, status: "email_accepted" });
  } catch {
    // Do not log request bodies, emails, tokens, provider responses, or secrets.
    return json(
      {
        error:
          "Sending could not be confirmed. Nothing was posted to GitHub. A retry may send another private email.",
      },
      502,
    );
  }
}
