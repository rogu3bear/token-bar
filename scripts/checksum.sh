#!/bin/bash
# Write <package>.sha256 naming only the installer basename.
#
# The sidecar is published beside the installer, so a downloader runs
# `shasum -a 256 -c` from their own directory: an absolute build path in the
# file leaks the maintainer's filesystem and fails that check for everyone.
# This is the single owner of that rule; every producer calls it, and calls it
# again after any step that changes the package bytes.
#
# Usage: scripts/checksum.sh <package>
set -euo pipefail
pkg="${1:-}"
[ -n "$pkg" ] || { echo "usage: scripts/checksum.sh <package>" >&2; exit 2; }
[ -f "$pkg" ] || { echo "checksum.sh: no such package: $pkg" >&2; exit 2; }
# CDPATH can redirect a relative cd to an unrelated directory and print the
# destination, so resolve once with it disabled and work from the absolute path.
dir=$(CDPATH= cd "$(dirname "$pkg")" && pwd)
name=$(basename "$pkg")
# Hash before writing: a redirect would leave an empty sidecar behind a failure.
line=$(cd "$dir" && shasum -a 256 "$name")
printf '%s\n' "$line" > "$dir/$name.sha256"
