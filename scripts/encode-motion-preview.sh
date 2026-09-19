#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
capture=${1:?Usage: encode-motion-preview.sh capture-directory}
# Native sample replay: retain both faces while dissolving back to the loop
# frame. Quota declines within the sample; the dissolve restarts that sample.
eval "$(python3 -c '
import json
from pathlib import Path
d = json.loads(Path("site/motion-preview.json").read_text())
print("fps=%s" % d["fps"])
print("loop_frame=%04d" % d["loopFrame"])
print("poster_frame=%04d" % d["posterFrame"])
print("fade_start=%s" % d["fadeStart"])
print("fade_duration=%s" % d["fadeDuration"])
print("duration=%s" % d["duration"])
')"
for surface in dashboard menu; do
  output=$surface
  if [[ "$surface" == menu ]]; then output=menu-bar; fi
  ffmpeg -hide_banner -loglevel error -y \
    -framerate "$fps" -i "$capture/$surface-%04d.png" \
    -loop 1 -framerate "$fps" -i "$capture/$surface-$loop_frame.png" \
    -filter_complex "[1:v]format=rgba,fade=t=in:st=$fade_start:d=$fade_duration:alpha=1[replay];[0:v][replay]overlay=shortest=1:format=auto,format=yuv420p[out]" \
    -map '[out]' -t "$duration" -c:v libx264 -preset medium -crf 18 \
    -movflags +faststart "site/public/$output-demo.mp4"
  # Still/reduced-motion visitors see Codex first; Claude enters in playback.
  cp "$capture/$surface-$poster_frame.png" "site/public/$output-demo.png"
done
