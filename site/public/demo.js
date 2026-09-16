fetch("/release.json")
  .then((response) => (response.ok ? response.json() : null))
  .then((release) => {
    if (!release) return;
    document.querySelector("#release-status").textContent = release.status;
    if (
      release.available &&
      release.url.startsWith(
        "https://github.com/rogu3bear/token-bar/releases/download/",
      )
    ) {
      const link = document.querySelector("#download");
      link.href = release.url;
      link.textContent = `Download v${release.version} .pkg ↓`;
    }
  })
  .catch(() => {});

const recordings = [document.querySelector("#dashboard-recording"), document.querySelector("#menu-recording")];
const [dashboard, menu] = recordings;
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const play = document.querySelector("#demo-play");
const status = document.querySelector("#recording-status");
let playing = false;
let starting = false;
let failed = false;
let userPaused = false;
let inView = false;
let pageActive = true;
let generation = 0;
const mayPlay = () => inView && pageActive && !document.hidden && !reducedMotion.matches && !userPaused && !failed;

function controls() {
  play.ariaLabel = playing ? "Pause preview" : "Play preview";
  play.title = play.ariaLabel;
  document.querySelector("#demo-icon").textContent = playing ? "Ⅱ" : "▶";
  play.disabled = failed || reducedMotion.matches;
  if (failed) {
    status.textContent = "Warning: Recording unavailable. The still previews show the native app.";
    status.classList.remove("visually-hidden");
    status.classList.add("warning");
  } else if (reducedMotion.matches) status.textContent = "Motion reduced — still previews";
}
function pause(message = "Paused") {
  generation++;
  starting = false;
  playing = false;
  recordings.forEach(video => video.pause());
  status.textContent = message;
  controls();
}
function seek(video, time) {
  return new Promise((resolve, reject) => {
    let timeout;
    const finish = error => {
      clearTimeout(timeout);
      video.removeEventListener("seeked", done);
      video.removeEventListener("error", failed);
      if (error) reject(error); else resolve();
    };
    const done = () => finish();
    const failed = () => finish(new Error("Recording seek failed"));
    video.addEventListener("seeked", done);
    video.addEventListener("error", failed);
    timeout = setTimeout(failed, 4000);
    video.currentTime = time;
    if (!video.seeking) done();
  });
}
async function start(restart = false) {
  if (starting || !mayPlay()) return;
  const attempt = ++generation;
  starting = true;
  playing = true;
  controls();
  try {
    const loopTime = Number(dashboard.dataset.loopStart) || 0;
    const startTime = Number(dashboard.dataset.start);
    if (restart || dashboard.ended) {
      await Promise.all(recordings.map(video => seek(video, loopTime)));
    } else if (Number.isFinite(startTime) && dashboard.currentTime === 0) {
      await Promise.all(recordings.map(video => seek(video, startTime)));
    }
    if (attempt !== generation || !mayPlay()) return;
    await Promise.all(recordings.map(async video => {
      await video.play();
      // Enforce cancellation per video even when its peer never settles.
      // A newer active request may legitimately keep this video playing.
      if (!playing || !mayPlay()) video.pause();
    }));
    if (attempt === generation && mayPlay()) {
      status.textContent = "Native recording · sample data";
    }
  } catch {
    if (attempt !== generation) return;
    recordings.forEach(recording => { delete recording.dataset.ready; });
    userPaused = true;
    pause("Preview paused. Select Play preview to resume.");
  } finally {
    if (attempt === generation) {
      starting = false;
      controls();
    }
  }
}
function update() {
  if (mayPlay()) { if (!playing) void start(); }
  else pause(userPaused ? "Paused" : "Native recording · sample data");
}
play.addEventListener("click", () => {
  userPaused = playing;
  if (userPaused) pause(); else void start();
});
dashboard.addEventListener("timeupdate", () => {
  if (playing && menu.readyState >= 1 && Math.abs(menu.currentTime - dashboard.currentTime) > 0.15) {
    menu.currentTime = dashboard.currentTime;
  }
});
dashboard.addEventListener("ended", () => {
  if (!mayPlay()) return pause();
  recordings.forEach(video => video.pause());
  void start(true);
});
recordings.forEach(video => {
  video.controls = false;
  video.muted = true;
  video.addEventListener("playing", () => {
    if (playing && mayPlay()) video.dataset.ready = "true";
    else video.pause();
  });
  video.addEventListener("error", () => {
    recordings.forEach(recording => { delete recording.dataset.ready; });
    failed = true;
    pause("Recording unavailable. The still previews show the native app.");
  });
});
const visible = new Set();
const observer = new IntersectionObserver(entries => {
  for (const entry of entries) {
    if (entry.isIntersecting) visible.add(entry.target); else visible.delete(entry.target);
  }
  inView = visible.size > 0;
  update();
}, { threshold: 0.05 });
recordings.forEach(video => observer.observe(video));
reducedMotion.addEventListener("change", update);
document.addEventListener("visibilitychange", update);
window.addEventListener("pagehide", () => { pageActive = false; pause(); });
window.addEventListener("pageshow", () => { pageActive = true; update(); });
document.querySelector(".recording-controls").hidden = false;
controls();
