const form = document.querySelector("#feedback-form");
const button = document.querySelector("#send");
const status = document.querySelector("#form-status");
const issueLink = document.querySelector("#issue-link");
let token = "";
let widget;
function showStatus(message, kind = "info") {
  status.classList.remove("error", "warning", "success");
  if (kind !== "info") status.classList.add(kind);
  status.textContent = message ? (kind === "error" ? "Error: " : kind === "warning" ? "Warning: " : "") + message : "";
}
const version = new URLSearchParams(location.search).get("version") || "";
if (/^[\w.\-]{1,40}$/.test(version)) form.elements.version.value = version;
// Version is convenience metadata only. Contact fields never enter the URL.
history.replaceState(null, "", location.pathname);
async function configure() {
  const response = await fetch("/api/config");
  if (!response.ok) throw new Error("unavailable");
  const config = await response.json();
  if (!config.available || !config.siteKey) throw new Error("unavailable");
  await new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src =
      "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
    script.onload = resolve;
    script.onerror = reject;
    document.head.append(script);
  });
  widget = window.turnstile.render("#verification", {
    sitekey: config.siteKey,
    action: "feedback",
    theme: "dark",
    callback: (value) => {
      token = value;
      button.disabled = false;
      showStatus("");
    },
    "expired-callback": () => {
      token = "";
      button.disabled = true;
      showStatus("Verification expired. Please verify again.", "warning");
    },
    "error-callback": () => {
      token = "";
      button.disabled = true;
      showStatus("Verification could not load. Please reload or try again later.", "error");
    },
  });
}
configure().catch(() => {
  showStatus("Private feedback is currently unavailable. Please try again later. You can also open an issue on GitHub directly, without including your email.", "warning");
});
form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!token || button.disabled) return;
  button.disabled = true;
  issueLink.classList.add("hidden");
  showStatus("Sending your report privately…");
  const data = Object.fromEntries(new FormData(form));
  const payload = {
    title: data.title,
    description: data.description,
    version: data.version,
    email: data.email,
    consent: form.elements.consent.checked,
    token,
  };
  try {
    const response = await fetch("/api/feedback", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(30000),
    });
    const result = await response.json();
    if (!response.ok)
      throw new Error(result.error || "Your report could not be sent.");
    const url = new URL(result.issueURL);
    if (
      url.origin !== "https://github.com" ||
      url.pathname !== "/rogu3bear/token-bar/issues/new"
    )
      throw new Error("The issue draft URL could not be verified.");
    showStatus("The email provider accepted your private report. Next, review the GitHub draft and submit it if you want a public issue. Your email is not included.", "success");
    issueLink.href = url.href;
    issueLink.classList.remove("hidden");
    form.elements.email.value = "";
    button.textContent = "Private report accepted";
    token = "";
    issueLink.focus();
  } catch (error) {
    showStatus(
      error.name === "TimeoutError"
        ? "Sending could not be confirmed. Nothing was posted to GitHub. A retry may send another private email."
        : error.message,
      error.name === "TimeoutError" ? "warning" : "error",
    );
    token = "";
    if (widget !== undefined) window.turnstile.reset(widget);
  }
});
