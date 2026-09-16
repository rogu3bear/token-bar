#!/bin/bash
# Build first. Two fresh processes must produce identical canonical stills.
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?Usage: bash scripts/verify-product-previews.sh new-output-directory}
[[ ! -e "$output" ]] || { echo 'Output directory must be new' >&2; exit 1; }
mkdir -p "$output/first" "$output/second"
binary='build/Token Bar.app/Contents/MacOS/TokenBar'
for pass in first second; do
  "$binary" --render-preview "$output/$pass/now.png"
  "$binary" --render-cost-preview "$output/$pass/cost.png"
  "$binary" --render-cost-preview "$output/$pass/history.png" --sample-history
done
for page in now history cost; do
  cmp "$output/first/$page.png" "$output/second/$page.png"
  cp "$output/first/$page.png" "$output/$page.png"
done
shasum -a 256 "$output/now.png" "$output/history.png" "$output/cost.png" > "$output/SHA256SUMS"
printf '%s\n' 'PASS: Now, History and Cost stills match across independent processes' 'Dark / Lime / synthetic UTC fixture / shipping DashboardRoot' > "$output/verification.txt"
cat "$output/verification.txt"
