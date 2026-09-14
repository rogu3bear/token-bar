#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
capture=${1:?Usage: encode-motion-preview.sh capture-directory}
# Native sample replay: retain both faces while dissolving back to frame 1359
# (45.3s). Quota declines within the sample; the dissolve restarts that sample.
for surface in dashboard menu; do
  output=$surface
  if [[ "$surface" == menu ]]; then output=menu-bar; fi
  ffmpeg -hide_banner -loglevel error -y \
    -framerate 30 -i "$capture/$surface-%04d.png" \
    -loop 1 -framerate 30 -i "$capture/$surface-1359.png" \
    -filter_complex '[1:v]format=rgba,fade=t=in:st=62.8:d=0.8:alpha=1[replay];[0:v][replay]overlay=shortest=1:format=auto,format=yuv420p[out]' \
    -map '[out]' -t 63.8 -c:v libx264 -preset medium -crf 18 \
    -movflags +faststart "site/public/$output-demo.mp4"
  # Still/reduced-motion visitors see Codex first; Claude enters in playback.
  cp "$capture/$surface-0105.png" "site/public/$output-demo.png"
done
